require 'ruby_llm'
require 'redcarpet'



class ChatStreamService
    
    def initialize()
        Dotenv.load
        RubyLLM.configure do |config|
                config.openrouter_api_key = ENV['OPENROUTER_API']
        end
        @chat = RubyLLM.chat(model: 'google/gemini-2.0-flash-001')
        renderer = Redcarpet::Render::HTML.new(filter_html: true, no_styles: true, safe_links_only: true)
        @markdown = Redcarpet::Markdown.new(renderer, autolink: true, tables: true, fenced_code_blocks: true)
    end

    def call(user_message, sinatra_out)
        full_response = ""
        
        # Collect the complete response first
        @chat.ask(user_message) do |chunk|
            full_response += chunk.content
        end
        
        # Convert to markdown HTML
        rendered_markdown = @markdown.render(full_response)
        
        # Stream the HTML character by character
        rendered_markdown.each_char do |char|
            sinatra_out << "data: #{char}\n\n"
        end
        
        # Signal completion
        sinatra_out << "event: complete\ndata: done\n\n"
    end

end