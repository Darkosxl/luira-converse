require 'ruby_llm'
require 'redcarpet'

# Custom renderer for better code formatting
class CustomHTMLRenderer < Redcarpet::Render::HTML
    def block_code(code, language)
        # Clean up the code formatting
        formatted_code = code.strip.gsub(/\s+$/, '') # Remove trailing whitespace
        language_class = language ? " class=\"language-#{language}\"" : ""
        "<pre><code#{language_class}>#{formatted_code}</code></pre>"
    end
    
    def codespan(code)
        "<code>#{code}</code>"
    end
end



class ChatStreamService
    
    def initialize()
        Dotenv.load
        RubyLLM.configure do |config|
                config.openrouter_api_key = ENV['OPENROUTER_API']
        end
        @chat = RubyLLM.chat(model: 'google/gemini-2.0-flash-001')
        renderer = CustomHTMLRenderer.new(filter_html: false, no_styles: false, safe_links_only: true)
        @markdown = Redcarpet::Markdown.new(renderer, autolink: true, tables: true, fenced_code_blocks: true, space_after_headers: true)
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