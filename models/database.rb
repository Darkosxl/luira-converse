require 'sequel'
require 'pg'
require 'securerandom'
require 'dotenv'
require 'bcrypt'

class Database
  
  def initialize
    Dotenv.load
    @db = Sequel.connect(ENV['POSTGRES_URL'],
      max_connections: 40,  # Increased from 20
      pool_timeout: 15,     # Increased from 10
      single_threaded: false,
      preconnect: true,
      test: true
    )
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
        createdAt: Time.now
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
        @db[:Chat].where(id: id).update(title: message)
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

  def delete_chat_by_id(id)
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
    @db[:User].insert(id: id, email: email, password_hash: password_hash, createdAt: Time.now, account_type: "free")
    return id
  end
  
  #user login
  def get_user(email, password)
    user = @db[:User].where(email: email).first
    return 404 unless user
    return BCrypt::Password.new(user[:password_hash]) == password ? user[:id] : 404
  end
  
  def get_user_by_id(user_id)
    @db[:User].where(id: user_id).first
  end
  
 def user_exists?(email)
   @db[:User].where(email: email).count > 0
 end

  def get_chats
    @db[:Chat].order(Sequel.desc(:createdAt)).all
  end

  def get_messages_by_chat_id(id)
    @db[:Message_v2].where(chatId: id).order(Sequel.asc(:createdAt)).all
  end
  
  private

  def generate_id
    SecureRandom.uuid
  end
end
