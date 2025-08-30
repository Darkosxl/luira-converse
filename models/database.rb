require 'sequel'
require 'pg'

class Database
  
  def initialize
    @db = Sequel.connect(ENV['POSTGRES_URL'])
    @sectors = [] 
    @subsectors = []
    @subsector_metrics = []
    @metrics = []
    @chat_history = []
    @vc_firms = []
    @startups = []
  end

  def get_sectors
    @sectors = db["SELECT DISTINCT trim(unnest(string_to_array(categories, ','))) AS sector FROM funding_rounds_v2 ORDER BY sector"]
  end
  
  def get_subsectors
    @subsectors = db["SELECT DISTINCT trim(unnest(string_to_array(categories, ','))) AS subsector FROM funding_rounds_v2 ORDER BY subsector"]
  end

  def get_metrics
    @metrics = ['Current Market Size', 'CAGR', 'Total Exits / Total Investments', 'AUM', 'Ticket Size', ' Follow on Index', 'Exit Multiple']
  end
  def get_subsector_metrics
    @subsector_metrics = ['Series #', 'subsector specific exit / investment']
  end

  def get_chat_history
    @chat_history
  end

  def add_chat_message(message, timestamp = Time.now)
    @chat_history << {
      message: message,
      timestamp: timestamp,
      id: generate_id
    }
  end

  def clear_chat_history
    @chat_history = []
  end

  def get_vc_firms
    @vc_firms
  end

  def add_vc_firm(firm)
    @vc_firms << firm unless @vc_firms.include?(firm)
  end

  def get_startups
    @startups
  end

  def add_startup(startup)
    @startups << startup unless @startups.include?(startup)
  end

  def reset_all_data
    @sectors = []
    @subsectors = []
    @subsector_metrics = []
    @metrics = []
    @chat_history = []
    @vc_firms = []
    @startups = []
  end

  private

  def generate_id
    Time.now.to_f.to_s.gsub('.', '')
  end
end
