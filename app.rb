require 'sinatra'
require 'erb'
require 'ruby_llm'
require 'dotenv'
require 'sinatra/sse'
require 'date'
require 'redcarpet'
require 'json'
require 'net/http'
require 'shield'
require 'rack/attack'

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
class User
  attr_reader :id, :username, :role
  
  def initialize(id, username, role)
    @id = id
    @username = username
    @role = role
  end
  
  # Shield expects this method
  def self.[](id)
    new(id, 'admin', 'admin') if id == 1
  end
  
  def self.authenticate(password, *args)
    require 'bcrypt'
    password_hash = ENV['PASSWORD_HASH'] || BCrypt::Password.create('1qa3ed5tg', cost: 12)
    if BCrypt::Password.new(password_hash) == password
      # Return admin user - full access to everything
      new(1, 'admin', 'admin')
    else
      nil
    end
  end
  
  def admin?
    true  # Always admin - keep it simple
  end
end

class SinatraRouter < Sinatra::Base
    set :bind, '0.0.0.0'
    set :port, 4567
    set :server, 'puma'
    
    # Security middleware
    use Rack::Attack
    helpers Shield::Helpers
    
    use Rack::Session::Cookie,
      key: 'app.session',
      secret: ENV['SESSION_SECRET'] || 'change-this-in-production-' + SecureRandom.hex(16),
      expire_after: 3600,
      httponly: true,
      secure: ENV['RACK_ENV'] == 'production'
    
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
        
        # Skip auth for login/health routes
        pass if request.path_info =~ /^\/(login|logout|health)$/
        
        # Require authentication for everything else
        unless authenticated(User)
            session[:return_to] = request.fullpath
            redirect '/login'
        end
        
        # Set up user context - admin can access everything
        @current_user = current_user
        @is_admin = admin?
        
        @database = Database.new()
        @conversation = ConversationHost.new()
    end
    get '/health' do
        'OK'
    end
    
    get '/login' do
        erb :'login'
    end
    
    post '/login' do
        if login(User, params[:password], session.delete(:return_to) || '/chat')
            redirect session[:return_to] || '/chat'
        else
            @error = "Invalid password"
            erb :login
        end
    end
    
    get '/logout' do
        logout(User)
        redirect '/login'
    end

    get '/' do
       erb :'landing-page'
    end
    get '/chat' do
        @show_welcome = session[:first_visit] != false
        @left_sidebar_open = session[:left_sidebar_open] || false
        @right_sidebar_open = session[:right_sidebar_open] || false
        erb :'chat'
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
        use_luira = params[:use_luira] == 'true'
        chat_id = @database.update_or_create_chat("private", user_message, session[:current_chat_id])
        session[:current_chat_id] = chat_id
        session[:first_visit] = false

        ai_id = "ai-response-#{Time.now.to_f.to_s.gsub('.', '')}"
        
        Thread.new do
            if use_luira
                @conversation.call_luira(user_message, ai_id, chat_id, @database)
            else
                @conversation.call_capmap(user_message, ai_id, chat_id, @database)
            end
        end

        user_html = erb :user_message, layout: false, locals: {message: user_message}
        logo_src = use_luira ? "/logo_luira.svg" : "/logo.svg"
        ai_placeholder = "<div id=\"#{ai_id}\" class=\"flex justify-start mb-6\"><div class=\"flex items-start gap-3 max-w-2xl\"><div class=\"ai-avatar-container ai-loading\"><img src=\"#{logo_src}\" class=\"logo-loading\" alt=\"Loading\"></div><div class=\"text-gray-900 flex-1 min-w-0 break-words\"><div class=\"typing-indicator\">AI is thinking...</div></div></div></div>"
        
        # Start SSE connection immediately
        sse_script = "<script>startAIStream('', '#{ai_id}');</script>"
        
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
    
    

    # Chat history routes
    get '/chat/history' do
        chats = @database.get_chats
        grouped_chats = group_chats_by_date(chats)
        
        content_type 'text/html'
        erb :chat_history, layout: false, locals: { grouped_chats: grouped_chats }
    end

    delete '/chat/:id' do
        chat_id = params[:id]
        @database.delete_chat_by_id(chat_id)
        
        # Return updated chat history
        chats = @database.get_chats
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