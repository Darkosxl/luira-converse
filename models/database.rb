require 'sequel'
require 'pg'

class Database
  
  def initialize
    @db = Sequel.connect(ENV['POSTGRES_URL'])
  end

  def get_chat_by_id(id)
    @db.select().from(:Chat).where(id: id).first
  end

  def get_or_create_chat(id, title, visibility)
    @db[:Chat].insert(id: id, title: title, visibility: visibility)
  end

  def update_chat(id, title, visibility)
    @db[:Chat].where(id: id).update(title: title, visibility: visibility)
  end

  def delete_chat_by_id(id)
    @db[:Vote].where(chatId: id).delete
    @db[:Message_v2].where(chatId: id).delete
    @db[:Stream].where(chatId: id).delete
    @db[:Chat].where(id: id).delete
  end

  def get_chats
    @db[:Chat].order(Sequel.desc(:createdAt)).all
  end

  def save_messages(messages)
    @db[:Message_v2].multi_insert(messages)
  end

  def get_messages_by_chat_id(id)
    @db[:Message_v2].where(chatId: id).order(:createdAt).all
  end

  private

  def generate_id
    Time.now.to_f.to_s.gsub('.', '')
  end
end
