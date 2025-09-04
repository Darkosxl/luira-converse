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
    # Use class variable for shared storage across instances
    @@completed_responses = {}
    
    def self.completed_responses
        @@completed_responses
    end
    
    def initialize()
        Dotenv.load
        RubyLLM.configure do |config|
                config.openrouter_api_key = ENV['OPENROUTER_API']
        end
        @chat = RubyLLM.chat(model: 'google/gemini-2.0-flash-001')
        renderer = CustomHTMLRenderer.new(filter_html: false, no_styles: false, safe_links_only: true)
        @markdown = Redcarpet::Markdown.new(renderer, autolink: true, tables: true, fenced_code_blocks: true, space_after_headers: true)
    end

    def call_capmap(user_message, ai_id, chat_id, database)
        require 'http'
        response = HTTP.post(ENV['VC_COPILOT_FLASK_URL'], 
            json: { message: user_message, general_agent_check: false })
        
        flask_response = JSON.parse(response.body.to_s)
        ai_message = flask_response['reply'] || response.body.to_s
        rendered_html = @markdown.render(ai_message)
        
        database.update_or_create_chat("private", ai_message, chat_id, "assistant")
        @@completed_responses[ai_id] = rendered_html
    end

    def call_luira(user_message, ai_id, chat_id, database)
        full_response = ""
        
        @chat.ask(user_message) do |chunk|
            full_response += chunk.content
        end
        
        rendered_html = @markdown.render(full_response)
        database.update_or_create_chat("private", full_response, chat_id, "assistant")
        @@completed_responses[ai_id] = rendered_html
    end

    
end