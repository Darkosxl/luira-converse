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
    @@chat_instances = {}

    def self.completed_responses
        @@completed_responses
    end

    # Model mapping for display names to actual model identifiers
    MODEL_MAPPING = {
        'claude-sonnet-4' => 'anthropic/claude-sonnet-4',
        'deepseek-chat-v3.1' => 'deepseek/deepseek-chat-v3.1',
        'gemini-2.5-pro' => 'google/gemini-2.5-pro',
        'gemini-2.5-flash' => 'google/gemini-2.5-flash',
        'gpt-4.1' => 'openai/gpt-4.1',
        'gpt-5-chat' => 'openai/gpt-5-chat',
        'r1-1776' => 'perplexity/r1-1776',
        'sonar-reasoning-pro' => 'perplexity/sonar-reasoning-pro',
        'qwen3-235b-thinking' => 'qwen/qwen3-235b-a22b-thinking-2507',
        'grok-4' => 'x-ai/grok-4',
        'o3-pro' => 'openai/o3-pro',
        'kimi-k2' => 'moonshotai/kimi-k2',
        'glm-4.5v' => 'z-ai/glm-4.5v'
    }

    def initialize()
        Dotenv.load
        RubyLLM.configure do |config|
            config.openrouter_api_key = ENV['OPENROUTER_API']
        end
        renderer = CustomHTMLRenderer.new(filter_html: false, no_styles: false, safe_links_only: true)
        @markdown = Redcarpet::Markdown.new(renderer, autolink: true, tables: true, fenced_code_blocks: true, space_after_headers: true)
    end

    def get_chat_instance(model_key, chat_id)
        # Use only chat_id as key to maintain conversation history across models
        instance_key = chat_id

        # Create new chat instance if it doesn't exist
        unless @@chat_instances[instance_key]
            model_name = MODEL_MAPPING[model_key] || 'google/gemini-2.0-flash-001'
            @@chat_instances[instance_key] = RubyLLM.chat(model: model_name)
            return @@chat_instances[instance_key]
        end

        # Switch to the requested model on existing instance
        model_name = MODEL_MAPPING[model_key] || 'google/gemini-2.0-flash-001'
        @@chat_instances[instance_key].with_model(model_name)
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

    def call_model(user_message, ai_id, chat_id, database, model_key = 'gemini-2.5-flash')
        if model_key == 'capmap'
            call_capmap(user_message, ai_id, chat_id, database)
        else
            call_luira_model(user_message, ai_id, chat_id, database, model_key)
        end
    end

    def call_luira_model(user_message, ai_id, chat_id, database, model_key)
        full_response = ""
        chat_instance = get_chat_instance(model_key, chat_id)

        chat_instance.ask(user_message) do |chunk|
            full_response += chunk.content
        end

        rendered_html = @markdown.render(full_response)
        database.update_or_create_chat("private", full_response, chat_id, "assistant")
        @@completed_responses[ai_id] = rendered_html
    end

    # Keep the old method for backward compatibility
    def call_luira(user_message, ai_id, chat_id, database)
        call_luira_model(user_message, ai_id, chat_id, database, 'gemini-2.5-flash')
    end

    
end