require 'ruby_llm'
require 'redcarpet'
require 'dotenv'



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

class ConversationHost
    def initialize()
        Dotenv.load
        RubyLLM.configure do |config|
                config.openrouter_api_key = ENV['OPENROUTER_API']
        end
        @chat = RubyLLM.chat(model: 'google/gemini-2.0-flash-001')
        renderer = CustomHTMLRenderer.new(filter_html: false, no_styles: false, safe_links_only: true)
        @markdown = Redcarpet::Markdown.new(renderer, autolink: true, tables: true, fenced_code_blocks: true, space_after_headers: true)
    end

    def call_capmap(user_message, ai_id, chat_id)
        require 'http'
        puts "🚀 Calling Flask backend..."
        response = HTTP.post(ENV['VC_COPILOT_FLASK_URL'], 
            json: { message: user_message,
        general_agent_check: false }
        )
        
        
        
        # Parse the Flask response to get the AI message
        flask_response = JSON.parse(response.body.to_s)
        ai_message = flask_response['reply'] || response.body.to_s
        
        # Post the AI response back to Sinatra

        result = Rack::MockRequest.new(SinatraRouter).post('/chat/ai_response', 
            input: { 
                content: ai_message,
                ai_id: ai_id,
                chat_id: chat_id
            }.to_json,
            'CONTENT_TYPE' => 'application/json'
        )
        puts "📨 Rack::MockRequest response: #{result.status} - #{result.body[0..100]}..."
        
    end

    def call_luira(user_message, sinatra_out)
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