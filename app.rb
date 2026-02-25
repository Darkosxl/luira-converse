require 'sinatra'
require 'erb'
require 'ruby_llm'
require 'dotenv'
require 'sinatra/sse'
require 'date'
require 'redcarpet'
require 'json'
require 'net/http'
require 'rack/attack'
require 'stripe'

require_relative 'models/stream'
require_relative 'models/database'
require_relative 'models/conversation'

# ==========================================
# SECURITY MIDDLEWARE CONFIGURATION
# ==========================================
Dotenv.load

# Configure Rack::Attack for rate limiting
if ENV['REDIS_URL']
  require 'redis'
  redis_url = ENV['REDIS_URL']
  redis_username = ENV['REDIS_USERNAME']
  redis_password = ENV['REDIS_PASSWORD']
  # Ensure Redis URL has proper scheme
  redis_url = "redis://#{redis_username}:#{redis_password}@#{redis_url}"
  Rack::Attack.cache.store = Redis.new(url: redis_url)
else
  # Use ActiveSupport memory store for fallback
  #require 'active_support/cache/memory_store'
  #Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
end

# Rate limiting rules (periods in seconds)
Rack::Attack.throttle('req/ip', limit: 100, period: 60) { |req| req.ip }
Rack::Attack.throttle('logins/ip', limit: 5, period: 900) do |req|
  req.ip if req.path == '/login' && req.post?
end
Rack::Attack.throttle('api/ip', limit: 20, period: 60) do |req|
  req.ip if req.path.start_with?('/chat')
end

# Block malicious requests
Rack::Attack.blocklist('bad-agents') do |req|
  bad_agents = /nikto|sqlmap|havij|acunetix|nessus|metasploit|morfeus|brutus|hydra|nmap/i
  req.user_agent =~ bad_agents if req.user_agent
end

Rack::Attack.blocklist('bad-requests') do |req|
  req.query_string =~ /(\%27)|(\')|(\-\-)|(\%23)|(#)/i ||
  req.query_string =~ /(union|select|insert|drop|delete|update|cast|declare|exec|script)/i ||
  req.path_info =~ /\.\./
end

# Block repeated 404s
Rack::Attack.blocklist('fail2ban') do |req|
  Rack::Attack::Fail2Ban.filter("pentesters-#{req.ip}", maxretry: 10, findtime: 60, bantime: 900) do
    req.env['sinatra.error'] && req.env['sinatra.error'].class == Sinatra::NotFound
  end
end

Rack::Attack.blocklisted_responder = lambda { |req| [403, {'Content-Type' => 'text/plain'}, ["Access denied.\n"]] }
Rack::Attack.throttled_responder = lambda do |req|
  retry_after = (req.env['rack.attack.match_data'] || {})[:period]
  [429, {'Content-Type' => 'text/plain', 'Retry-After' => retry_after.to_s}, ["Rate limit exceeded.\n"]]
end

# Authentication User class

class SinatraRouter < Sinatra::Base

    MODEL_TIERS = {
      'claude-opus-4-6'          => 'pro',
      'openai/gpt-5.2-codex'     => 'pro',
      'capmap'                   => 'advanced',
      'openai/gpt-5.2'           => 'advanced',
      'claude-sonnet-4-6'        => 'advanced',
      'gemini-3-pro'             => 'advanced',
      'gemini-3.1-pro'           => 'advanced',
      'openai/gpt-5.1-codex-max' => 'advanced',
      'minimax/minimax-m2.5'     => 'advanced',
      'moonshotai/kimi-k2.5'     => 'advanced',
      'gemini-3-flash'           => 'free',
      'qwen/qwen3.5-plus-02-15'  => 'free',
      'z-ai/glm-5'               => 'free',
    }.freeze

    TIER_RANK = { 'free' => 0, 'advanced' => 1, 'pro' => 2 }.freeze

    set :bind, '0.0.0.0'
    set :port, 4567
    set :server, 'puma'

    # Trust proxy headers (for SSL termination)
    set :protection, except: [:session_hijacking]
    set :forwarded, true

    # Initialize shared database and conversation instances at startup
    configure do
        @@database = Database.new()
        @@conversation = ConversationHost.new()
    end

    # Security middleware
    use Rack::Attack

    use Rack::Session::Cookie,
      key: 'app.session',
      secret: ENV['SESSION_SECRET'],
      expire_after: 3600,
      httponly: true,
      secure: false,  # Set to false since we're behind a reverse proxy
      same_site: :lax
    
    # Helper method to get current user
    def current_user
      authenticated(User)
    end
    
    # Helper method to check if current user is admin
    def admin?
      current_user&.admin?
    end
    
    before do
        # Security headers
        headers['X-Frame-Options'] = 'DENY'
        headers['X-Content-Type-Options'] = 'nosniff'
        headers['X-XSS-Protection'] = '1; mode=block'
        headers['Referrer-Policy'] = 'no-referrer'
        headers['Access-Control-Allow-Origin'] = 'none'
        # HSTS — browser-level enforcement (H-2); Cloudflare dashboard is the primary control
        headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains'
        # CSP — tightened once Tailwind CDN is removed (H-3)
        headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self' 'unsafe-inline' https://js.stripe.com; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-src https://js.stripe.com; frame-ancestors 'none'"

        @database = @@database
        @conversation = @@conversation
        # Skip auth for login/health/landing/register/robots/sitemap/pricing routes
        pass if request.path_info =~ /^\/(login|logout|health|register(\/send-code)?|stripe\/webhook|robots\.txt|sitemap\.xml|pricing)$/

        # Add noindex header to auth-only pages
        if request.path_info =~ /^\/(login|register)/
            headers['X-Robots-Tag'] = 'noindex, nofollow'
        end

        # Require authentication for everything else
        unless session[:user_id]
            session[:return_to] = request.fullpath    
            redirect '/login'
        end
    end
    get '/health' do
        'OK'
    end
    
    get '/login' do
        erb :'login'
    end
    
    post '/login' do
      user_id = @database.get_user(params[:email], params[:password])
      if user_id == 404
        @error = "User not found"
        erb :login
      else
        session[:user_id] = user_id
        redirect '/chat'
      end
    end
    
    get '/logout' do
        logout(User)
        redirect '/login'
    end

    get '/register' do
      erb :'register'
    end

    # Send a 6-digit verification code to the given email via Resend.
    # Stores the code in Redis with a 15-minute TTL keyed by email.
    post '/register/send-code' do
      content_type :json
      email = params[:email].to_s.strip.downcase

      unless email.match?(/\A[^@]+@[^@]+\.[^@]+\z/)
        halt 422, { error: 'Invalid email address.' }.to_json
      end

      code = rand(100_000..999_999).to_s

      # Store in Redis — key: verify:<email>, value: code, TTL: 900s
      redis = Redis.new(
        url: "redis://#{ENV['REDIS_USERNAME']}:#{ENV['REDIS_PASSWORD']}@#{ENV['REDIS_URL']}"
      )
      redis.set("verify:#{email}", code, ex: 900)

      # Send via Resend
      uri = URI('https://api.resend.com/emails')
      req = Net::HTTP::Post.new(uri)
      req['Authorization'] = "Bearer #{ENV['RESEND_API_KEY']}"
      req['Content-Type']  = 'application/json'
      req.body = {
        from:    ENV['EMAIL_FROM'],
        to:      [email],
        subject: 'Your Luira verification code',
        html:    <<~HTML
          <div style="font-family:sans-serif;max-width:480px;margin:0 auto;padding:32px;background:#050a30;color:#fff;border-radius:16px">
            <h2 style="margin:0 0 8px;font-size:22px">Verify your email</h2>
            <p style="color:#9ca3af;margin:0 0 24px">Enter this code on the registration page. It expires in 15 minutes.</p>
            <div style="letter-spacing:12px;font-size:40px;font-weight:700;text-align:center;padding:20px;background:rgba(121,16,255,0.15);border-radius:12px;border:1px solid rgba(121,16,255,0.3)">
              #{code}
            </div>
            <p style="color:#6b7280;font-size:12px;margin:24px 0 0">If you didn't request this, you can safely ignore this email.</p>
          </div>
        HTML
      }.to_json

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }

      { ok: true }.to_json
    rescue StandardError
      halt 500, { error: 'Failed to send email. Please try again.' }.to_json
    end

    post '/register' do
      email    = params[:email].to_s.strip.downcase
      code     = params[:verification_code].to_s.strip
      password = params[:password].to_s

      # 1. Validate code against Redis before touching the DB
      redis = Redis.new(
        url: "redis://#{ENV['REDIS_USERNAME']}:#{ENV['REDIS_PASSWORD']}@#{ENV['REDIS_URL']}"
      )
      stored = redis.get("verify:#{email}")

      if stored.nil?
        @error = 'Verification code expired or not sent. Please request a new one.'
        @prefill_email = email
        next erb :register
      end

      unless stored == code
        @error = 'Incorrect verification code. Please try again.'
        @prefill_email = email
        next erb :register
      end

      # 2. Code is valid — delete it so it can't be reused
      redis.del("verify:#{email}")

      # 3. Create the user
      user_id = @database.create_user(email, password)
      if user_id == 'User already exists'
        @error = user_id
        erb :register
      else
        session[:user_id] = user_id
        redirect '/chat'
      end
    end
    get '/' do
       erb :'landing-page'
    end

    get '/pricing' do
        erb :'pricing'
    end

    # ── SEO: public robots.txt (C-3) ─────────────────────────────────────────
    get '/robots.txt' do
        content_type 'text/plain'
        headers['Cache-Control'] = 'public, max-age=86400'
        <<~ROBOTS
            User-agent: *
            Disallow: /login
            Disallow: /register
            Disallow: /dashboard/
            Disallow: /cdn-cgi/
            Sitemap: https://luira.amoredit.com/sitemap.xml
        ROBOTS
    end

    # ── SEO: public sitemap.xml (C-4) ────────────────────────────────────────
    get '/sitemap.xml' do
        content_type 'application/xml'
        headers['Cache-Control'] = 'public, max-age=3600'
        <<~XML
            <?xml version="1.0" encoding="UTF-8"?>
            <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
              <url>
                <loc>https://luira.amoredit.com/</loc>
                <changefreq>weekly</changefreq>
                <priority>1.0</priority>
              </url>
            </urlset>
        XML
    end
    get '/chat' do
        # Clear current chat session to start fresh
        session.delete(:current_chat_id)
        @show_welcome = true
        @left_sidebar_open = session[:left_sidebar_open] || false
        @right_sidebar_open = session[:right_sidebar_open] || false
        @current_user = @database.get_user_by_id(session[:user_id])
        @request_info = @database.get_request_info(session[:user_id])
        erb :'chat'
    end
    get '/chat/request_info' do
        content_type 'text/html'
        request_info = @database.get_request_info(session[:user_id])
        erb :_request_info, layout: false, locals: { request_info: request_info }
    end

    get '/chat/available_sectors' do
        content_type :json
        sectors = @database.get_available_sectors
        { sectors: sectors }.to_json
    end
    get '/chat/available_subsectors' do
        content_type :json
        subsectors = @database.get_available_subsectors
        { subsectors: subsectors }.to_json
    end
    #USER INITITATES CHAT, OR SENDS MESSAGES, THOSE GET SAVED, AND THEY CALL THE BACKEND TO GET THE AI RESPONSE
    post '/chat/messages' do
        user_message = params[:message]
        model_key = params[:model] || 'z-ai/glm-5'

        # --- Model tier access gate ---

        user       = @database.get_user_by_id(session[:user_id])
        acct       = @database.effective_account_type(user).to_s.downcase
        acct       = 'free' unless TIER_RANK.key?(acct)
        model_tier = MODEL_TIERS[model_key] || 'free'

        if TIER_RANK[model_tier] > TIER_RANK[acct]
          upgrade_to = model_tier == 'pro' ? 'Pro' : 'Advanced'
          content_type :json
          halt 403, { error: "#{model_key.split('/').last} requires a #{upgrade_to} plan. Please upgrade to use this model." }.to_json
        end

        # --- Rate limit check (weighted by model cost) ---
        rate = @database.check_and_increment_requests(session[:user_id], model_key)
        unless rate[:allowed]
          content_type :json
          halt 429, { error: "Not enough requests remaining. This model costs #{rate[:cost]} request(s) and you have #{rate[:remaining]} left. Upgrade your plan for more.", remaining: rate[:remaining] }.to_json
        end

        chat_id = @database.update_or_create_chat("private", user_message, session[:current_chat_id], 'user', session[:user_id])
        session[:current_chat_id] = chat_id
        session[:first_visit] = false

        ai_id = "ai-response-#{Time.now.to_f.to_s.gsub('.', '')}"

        Thread.new do
            @conversation.call_model(user_message, ai_id, chat_id, @database, model_key)
        end

        user_html = erb :user_message, layout: false, locals: {message: user_message}
        # Use appropriate logo based on model
        logo_src = model_key == 'capmap' ? "/logo.svg" : "/logo_luira.svg"
        content_id = "#{ai_id}-content"
        ai_placeholder = <<~HTML
          <div id="#{ai_id}" class="flex justify-start mb-6">
            <div class="flex items-start gap-3 max-w-2xl w-full">
              <div class="ai-avatar-container flex-shrink-0">
                <img src="#{logo_src}" alt="AI">
              </div>
              <div class="flex flex-col gap-1 flex-1 min-w-0">
                <div id="#{content_id}-loader" class="inline-flex items-center gap-3 px-4 py-3 bg-gray-100 rounded-2xl rounded-tl-none">
                  <div class="typing-bubble">
                    <div class="typing-dot"></div>
                    <div class="typing-dot"></div>
                    <div class="typing-dot"></div>
                  </div>
                  <span class="text-xs font-medium text-gray-500">Analyzing Request...</span>
                </div>
                <div id="#{content_id}" class="hidden text-gray-900 break-words prose prose-sm max-w-none"></div>
              </div>
            </div>
          </div>
        HTML

        # Start SSE connection immediately
        sse_script = "<script>startAIStream('', '#{ai_id}', '#{content_id}');</script>"

        "#{user_html}#{ai_placeholder}#{sse_script}"
    end
    
    # SSE endpoint to stream AI responses
    get '/chat/stream/:ai_id' do
        content_type 'text/event-stream'
        cache_control 'no-cache'
        
        ai_id = params[:ai_id]
        
        stream do |out|
            while !ConversationHost.completed_responses[ai_id]
                sleep 0.1
            end
            
            ai_message = ConversationHost.completed_responses[ai_id]
            ConversationHost.completed_responses.delete(ai_id)
            
            ai_message.each_char do |char|
                out << "data: #{char}\n\n"
                sleep 0.003
            end
            
            out << "event: complete\ndata: done\n\n"
        end
    end
    
    # Sidebar toggle routes
    post '/toggle-left-sidebar' do
        session[:left_sidebar_open] = !session[:left_sidebar_open]
        @left_sidebar_open = session[:left_sidebar_open]
        
        content_type 'text/html'
        erb :sidebar, layout: false
    end
    
    post '/close-left-sidebar' do
        session[:left_sidebar_open] = false
        @left_sidebar_open = false
        
        content_type 'text/html'
        erb :sidebar, layout: false
    end
    
    post '/toggle-right-sidebar' do
        session[:right_sidebar_open] = !session[:right_sidebar_open]
        @right_sidebar_open = session[:right_sidebar_open]
        
        content_type 'text/html'
        erb :_agent_sidebar, layout: false
    end
    
    post '/close-right-sidebar' do
        session[:right_sidebar_open] = false
        @right_sidebar_open = false
        
        content_type 'text/html'
        erb :_agent_sidebar, layout: false
    end
    
    
    post '/create-checkout-session' do
      content_type 'application/json'
      production = ENV['RACK_ENV'] == 'production'
      Stripe.api_key = production ? ENV['STRIPE_API_KEY'] : ENV['STRIPE_DEV_API_KEY']

      plan = params[:plan] || 'advanced'

      price_ids = if production
        {
          'advanced' => ENV['LUIRA_ADVANCED_PRICE_ID'],
          'pro'      => ENV['LUIRA_PRO_PRICE_ID']
        }
      else
        {
          'advanced' => ENV['LUIRA_ADVANCED_TEST_PRICE_ID'],
          'pro'      => ENV['LUIRA_PRO_TEST_PRICE_ID']
        }
      end

      price_id = price_ids[plan] || price_ids['advanced']
      current_user_record = @database.get_user_by_id(session[:user_id])

      checkout_session = Stripe::Checkout::Session.create({
        line_items: [{
          price:    price_id,
          quantity: 1
        }],
        mode:                 'subscription',
        success_url:          "#{request.base_url}/chat?upgrade=#{plan}",
        cancel_url:           "#{request.base_url}/chat",
        client_reference_id:  session[:user_id].to_s,
        customer_email:       current_user_record[:email],
        # Embed the plan in metadata — we read this back in the webhook
        # instead of inferring from amount_total, so price changes don't break things.
        subscription_data: {
          metadata: { plan: plan, user_id: session[:user_id].to_s }
        }
      })

      redirect checkout_session.url, 303
    end

    # Pricing / plan selection page
    get '/plans' do
      @current_user = @database.get_user_by_id(session[:user_id])
      erb :'plans'
    end

    # Feedback submission
    post '/feedback' do
      return halt 401 unless session[:user_id]
      user  = @database.get_user_by_id(session[:user_id])
      return halt 401 unless user

      note = params[:note].to_s.strip
      return halt 422, { error: 'Note cannot be empty.' }.to_json if note.empty?

      plan = (user[:account_type] || 'free').downcase
      @database.create_feedback(user[:email], note, plan)

      content_type :json
      { ok: true }.to_json
    end

    # Stripe Customer Portal — lets paid users manage/cancel their subscription.
    # Stripe hosts the entire UI; we just create the session and redirect.
    post '/billing' do
      Stripe.api_key = ENV['RACK_ENV'] == 'production' ? ENV['STRIPE_API_KEY'] : ENV['STRIPE_DEV_API_KEY']
      current_user_record = @database.get_user_by_id(session[:user_id])
      stripe_customer_id  = current_user_record[:stripe_customer_id]

      if stripe_customer_id.nil? || stripe_customer_id.empty?
        # Free user with no Stripe record — send them to the plans page instead
        redirect '/plans'
      else
        portal = Stripe::BillingPortal::Session.create({
          customer:   stripe_customer_id,
          return_url: "#{request.base_url}/chat"
        })
        redirect portal.url, 303
      end
    end

    # Chat history routes
    get '/chat/history' do
        chats = @database.get_chats(session[:user_id])
        grouped_chats = group_chats_by_date(chats)
        
        content_type 'text/html'
        erb :chat_history, layout: false, locals: { grouped_chats: grouped_chats }
    end

    post '/stripe/webhook' do
      payload    = request.body.read
      sig_header = request.env['HTTP_STRIPE_SIGNATURE']

      # Use the right API key and webhook secret based on environment
      production = ENV['RACK_ENV'] == 'production'
      Stripe.api_key     = production ? ENV['STRIPE_API_KEY'] : ENV['STRIPE_DEV_API_KEY']
      webhook_secret     = production ? ENV['STRIPE_PROD_WEBHOOK_SECRET'] : ENV['STRIPE_WEBHOOK_SECRET']

      begin
        event = Stripe::Webhook.construct_event(
          payload, sig_header, webhook_secret
        )
      rescue Stripe::SignatureVerificationError => e
        halt 400, { error: e.message }.to_json
      rescue => e
        halt 400, { error: e.message }.to_json
      end

      case event['type']

      # ── User successfully subscribed ────────────────────────────────────
      when 'checkout.session.completed'
        checkout        = event['data']['object']
        user_id         = checkout['client_reference_id']
        subscription_id = checkout['subscription']

        # Only process subscription checkouts with a linked user
        if user_id && !user_id.empty? && subscription_id
          subscription = Stripe::Subscription.retrieve(subscription_id)
          plan         = subscription['metadata']['plan'] || 'advanced'
          period_end = subscription['current_period_end']
          ends_at    = period_end ? Time.at(period_end) : nil

          @database.change_user_plan(user_id, plan)
          @database.store_stripe_customer(
            user_id,
            checkout['customer'],
            subscription_id,
            ends_at
          )
        end

      # ── User cancelled — keep access until period end (grace period) ───
      when 'customer.subscription.deleted'
        sub             = event['data']['object']
        stripe_cust_id  = sub['customer']
        # current_period_end is when they actually paid up to.
        grace_ends_at   = Time.at(sub['current_period_end'])

        @database.schedule_downgrade(stripe_cust_id, grace_ends_at)

      # ── Payment failed — downgrade immediately ─────────────────────────
      # invoice.payment_failed fires on every failed attempt.
      # We only act on the final failure (next_payment_attempt is nil),
      # meaning Stripe has given up and the subscription will be cancelled.
      when 'invoice.payment_failed'
        invoice        = event['data']['object']
        stripe_cust_id = invoice['customer']

        if invoice['next_payment_attempt'].nil?
          # Stripe has exhausted retries — subscription is being killed.
          # Downgrade immediately, no grace period (they didn't pay).
          @database.downgrade_to_free_by_stripe_customer(stripe_cust_id)
        end

      end

      status 200
    end
    
    delete '/chat/:id' do
        chat_id = params[:id]
        @database.delete_chat_by_id(chat_id, session[:user_id])
        
        # Return updated chat history
        chats = @database.get_chats(session[:user_id])
        grouped_chats = group_chats_by_date(chats)
        
        content_type 'text/html'
        erb :chat_history, layout: false, locals: { grouped_chats: grouped_chats }
    end

    get '/chat/:id' do
        chat_id = params[:id]
        @current_chat = @database.get_chat_by_id(chat_id)
        messages = @database.get_messages_by_chat_id(chat_id)
        
        # Set up session variables that the chat template expects
        @show_welcome = false
        @left_sidebar_open = session[:left_sidebar_open] || false
        @right_sidebar_open = session[:right_sidebar_open] || false
        @current_user = @database.get_user_by_id(session[:user_id])
        @request_info = @database.get_request_info(session[:user_id])
        
        erb :chat, locals: { messages: messages }
    end

    # Error handlers
    not_found do
        status 404
        'Not found'
    end

    error do
        status 500
        'Internal server error'
    end

    private

    def group_chats_by_date(chats)
        now = Date.today
        
        grouped = {
            today: [],
            yesterday: [],
            last_week: [],
            last_month: [],
            older: []
        }
        
        chats.each do |chat|
            chat_date = Date.parse(chat[:createdAt].to_s)
            days_ago = (now - chat_date).to_i
            
            if days_ago == 0 
                grouped[:today] << chat
            elsif days_ago == 1
                grouped[:yesterday] << chat
            elsif days_ago <= 7
                grouped[:last_week] << chat
            elsif days_ago <= 30
                grouped[:last_month] << chat
            else
                grouped[:older] << chat
            end
        end
        
        grouped
    end
    
end

def main
    SinatraRouter.run!
end

main