class Database
  # Initialize with empty data structures
  def initialize
    @sectors = []
    @metrics = []
    @chat_history = []
    @vc_firms = []
    @startups = []
  end

  # Sectors for ranking model
  def get_sectors
    @sectors
  end

  def add_sector(sector)
    @sectors << sector unless @sectors.include?(sector)
  end

  # Metrics for ranking model
  def get_metrics
    @metrics
  end

  def add_metric(metric)
    @metrics << metric unless @metrics.include?(metric)
  end

  # Chat history management
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

  # VC firms for prediction models
  def get_vc_firms
    @vc_firms
  end

  def add_vc_firm(firm)
    @vc_firms << firm unless @vc_firms.include?(firm)
  end

  # Startups for prediction models
  def get_startups
    @startups
  end

  def add_startup(startup)
    @startups << startup unless @startups.include?(startup)
  end

  # General utility methods
  def reset_all_data
    @sectors = []
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
