require 'sequel'
require 'pg'
require 'securerandom'
require 'dotenv'
require 'bcrypt'

class Database

  MONTHLY_LIMITS = {
    'free'     => 30,
    'advanced' => 200,
    'pro'      => 500
  }.freeze

  # Cost in "requests" deducted per use, based on model.
  MODEL_COSTS = {
    'capmap'                   => 8,
    # Pro tier
    'claude-opus-4-6'          => 5,
    'openai/gpt-5.2-codex'     => 5,
    # Advanced tier
    'openai/gpt-5.2'           => 3,
    'claude-sonnet-4-6'        => 3,
    'gemini-3-pro'             => 3,
    'gemini-3.1-pro'           => 3,
    'openai/gpt-5.1-codex-max' => 3,
    'minimax/minimax-m2.5'     => 3,
    'moonshotai/kimi-k2.5'     => 3,
    # Free tier
    'gemini-3-flash'           => 1,
    'qwen/qwen3.5-plus-02-15'  => 1,
    'z-ai/glm-5'               => 1,
  }.freeze

  def initialize
    Dotenv.load
    @db = Sequel.connect(ENV['POSTGRES_URL'],
      max_connections: 40,
      pool_timeout: 15,
      single_threaded: false,
      preconnect: true,
      test: true
    )
    ensure_feedback_table!
  end
  def get_chat_by_id(id)
    @db.select().from(:Chat).where(id: id).first
  end
  #get or create chat
  
  def update_or_create_chat(visibility, message, id=nil, role='user', user_id)
    if id == nil or @db[:Chat].where(id: id).first.nil?
      chat_id = SecureRandom.uuid
      @db[:Chat].insert(
        id: chat_id, 
        title: message, 
        visibility: visibility, 
        userId: user_id, 
        createdAt: Time.now,
        updatedAt: Time.now
      )
      message_id = SecureRandom.uuid
      @db[:Message_v2].insert(
        id: message_id, 
        chatId: chat_id, 
        role: role, 
        parts: [{"type" => "text", "text" => message}].to_json,  
        attachments: [].to_json,
        createdAt: Time.now
      )
      return chat_id
    else
      if role == 'user'
        @db[:Chat].where(id: id).update(title: message, updatedAt: Time.now)
      end
      message_id = SecureRandom.uuid
      @db[:Message_v2].insert(
        id: message_id, 
        chatId: id, 
        role: role, 
        parts: [{"type" => "text", "text" => message}].to_json, 
        attachments: [].to_json,
        createdAt: Time.now
      )
      return id
    end
  end

  def change_user_plan(user_id, plan)
    @db[:User].where(id: user_id).update(account_type: plan, updatedAt: Time.now)
  end

  # Saves a feedback note from a user.
  def create_feedback(user_email, note, plan)
    @db[:Feedback].insert(
      user_email:   user_email,
      note:         note,
      plan:         plan,
      created_at:   Time.now
    )
  end

  # Called after checkout.session.completed — stores Stripe IDs for future lookups.
  def store_stripe_customer(user_id, stripe_customer_id, stripe_subscription_id, subscription_ends_at)
    @db[:User].where(id: user_id).update(
      stripe_customer_id:      stripe_customer_id,
      stripe_subscription_id:  stripe_subscription_id,
      subscription_ends_at:    subscription_ends_at,
      updatedAt:               Time.now
    )
  end

  # Called on customer.subscription.deleted — sets ends_at so the grace period is preserved.
  # The user stays on their plan until subscription_ends_at passes, then gets downgraded.
  # Pass nil for immediate downgrade (e.g. invoice payment failure).
  def schedule_downgrade(stripe_customer_id, ends_at)
    @db[:User].where(stripe_customer_id: stripe_customer_id).update(
      subscription_ends_at: ends_at,
      updatedAt:            Time.now
    )
  end

  # Immediately downgrades to free. Used for hard failures (e.g. repeated payment failure).
  def downgrade_to_free_by_stripe_customer(stripe_customer_id)
    @db[:User].where(stripe_customer_id: stripe_customer_id).update(
      account_type:            'free',
      stripe_subscription_id:  nil,
      subscription_ends_at:    nil,
      updatedAt:               Time.now
    )
  end

  # Find user by Stripe customer ID (used in webhook handler).
  def get_user_by_stripe_customer(stripe_customer_id)
    @db[:User].where(stripe_customer_id: stripe_customer_id).first
  end
  
  def get_available_sectors
    query = %q(SELECT DISTINCT "Sector" FROM vc_sector_based_raw WHERE "Sector" IS NOT NULL ORDER BY "Sector")
    @db.fetch(query).map(:Sector)
  end

  def get_available_subsectors
    query = %q(
      WITH sectors_exploded AS (
          SELECT TRIM(unnest(string_to_array(COALESCE(fr.categories, ''), ','))) AS sector
          FROM funding_rounds_v2 fr
          WHERE fr.categories IS NOT NULL AND fr.categories <> ''
      )
      SELECT DISTINCT sector
      FROM sectors_exploded
      WHERE sector IS NOT NULL 
        AND sector <> ''
        AND sector <> '#NAME? ()'
      ORDER BY sector
      LIMIT 100
    )
    @db.fetch(query).map(:sector)
  end

  # --- Document Agent Specific Methods --- #
  def get_document_names
    # This method is not provided in the original file, so it's not included in the new_code.
    # If it were to be added, it would go here.
  end

  def delete_chat_by_id(id, user_id)
    # Ownership guard — only delete if the chat belongs to this user
    return unless @db[:Chat].where(id: id, userId: user_id).first

    @db[:Vote].where(chatId: id).delete
    @db[:Message_v2].where(chatId: id).delete
    @db[:Stream].where(chatId: id).delete
    @db[:Chat].where(id: id).delete
  end
  
  #user register
  def create_user(email, password)
    if @db[:User].where(email: email).first
      return "User already exists"
    end
    password_hash = BCrypt::Password.create(password, cost: 12)
    id = SecureRandom.uuid
    @db[:User].insert(id: id, email: email, password: password_hash, createdAt: Time.now, updatedAt: Time.now, account_type: "free")
    return id
  end
  
  #user login
  def get_user(email, password)
    user = @db[:User].where(email: email).first
    return 404 unless user
    return BCrypt::Password.new(user[:password]) == password ? user[:id] : 404
  end
  
  def get_user_by_id(user_id)
    @db[:User].where(id: user_id).first
  end
  
 def user_exists?(email)
   @db[:User].where(email: email).count > 0
 end

  def get_chats(user_id)
    @db[:Chat].where(userId: user_id).order(Sequel.desc(:createdAt)).all
  end

  def get_messages_by_chat_id(id)
    @db[:Message_v2].where(chatId: id).order(Sequel.asc(:createdAt)).all
  end
  
  # Check limit, increment counter by model cost, auto-reset on month rollover.
  # Returns { allowed:, count:, limit:, remaining:, cost: }
  def check_and_increment_requests(user_id, model_key = 'z-ai/glm-5')
    user = @db[:User].where(id: user_id).first
    return { allowed: true, count: 0, limit: 9999, remaining: 9999, cost: 1 } unless user

    cost = MODEL_COSTS[model_key] || 1

    now       = Time.now
    reset_at  = user[:requests_reset_at] || now
    new_month = reset_at.year != now.year || reset_at.month != now.month

    current_count = new_month ? 0 : (user[:monthly_requests] || 0)
    account_type  = effective_account_type(user, now)
    limit         = MONTHLY_LIMITS[account_type] || MONTHLY_LIMITS['free']

    return { allowed: false, count: current_count, limit: limit, remaining: [limit - current_count, 0].max, cost: cost } if current_count + cost > limit

    new_count   = current_count + cost
    update_data = { monthly_requests: new_count, updatedAt: now }
    update_data[:requests_reset_at] = now if new_month
    @db[:User].where(id: user_id).update(update_data)

    { allowed: true, count: new_count, limit: limit, remaining: limit - new_count, cost: cost }
  end

  # Read-only snapshot for the UI widget (no increment).
  def get_request_info(user_id)
    user = @db[:User].where(id: user_id).first
    return nil unless user

    now      = Time.now
    reset_at = user[:requests_reset_at] || now
    new_month = reset_at.year != now.year || reset_at.month != now.month

    count        = new_month ? 0 : (user[:monthly_requests] || 0)
    account_type = effective_account_type(user, now)
    limit        = MONTHLY_LIMITS[account_type] || MONTHLY_LIMITS['free']

    { count: count, limit: limit, remaining: [limit - count, 0].max }
  end

  # Resolves the user's actual plan at the moment of the call.
  # If subscription_ends_at is set and has passed, the user is treated as 'free'
  # even if account_type still shows 'advanced' or 'pro'.
  # This means grace period works without any cron jobs — it resolves on every request.
  def effective_account_type(user, now = Time.now)
    ends_at = user[:subscription_ends_at]
    if ends_at && now > ends_at
      'free'
    else
      (user[:account_type] || 'free').downcase
    end
  end

  private

  def generate_id
    SecureRandom.uuid
  end

  # Creates the Feedback table if it doesn't already exist.
  def ensure_feedback_table!
    @db.create_table?(:Feedback) do
      primary_key :id
      String      :user_email, null: false
      Text        :note,       null: false
      String      :plan,       null: false, default: 'free'
      DateTime    :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
