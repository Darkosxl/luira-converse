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
    'claude-opus-4.5' => 'anthropic/claude-opus-4-5',
    'claude-sonnet-4.5' => 'anthropic/claude-sonnet-4-5',
    'deepseek-v3.2' => 'deepseek/deepseek-v3.2',
    'gemini-3-pro' => 'google/gemini-3-pro',
    'gemini-2.5-flash' => 'google/gemini-2.5-flash',
    'gpt-5.2' => 'openai/gpt-5.2',
    'perplexity-sonar-pro-search' => 'perplexity/sonar-pro-search',
    'perplexity-sonar-reasoning-pro' => 'perplexity/sonar-reasoning-pro',
    'qwen3-VL-thinking-235B' => 'qwen/qwen3-vl-235b-a22b-thinking',
    'grok-4.1-fast' => 'x-ai/grok-4.1-fast',
    'kimi-k2-thinking' => 'moonshotai/kimi-k2-thinking',
    'glm-4.6' => 'z-ai/glm-4.6'
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

        # Use chat_id as session identifier for Flask
        response = HTTP.cookies(session: chat_id)
            .timeout(connect: 10, read: 90)
            .post(ENV['VC_COPILOT_FLASK_URL'],
                json: { message: user_message, general_agent_check: false })

        flask_response = JSON.parse(response.body.to_s)
        ai_message = flask_response['reply'] || response.body.to_s
        rendered_html = @markdown.render(ai_message)

        database.update_or_create_chat("private", ai_message, chat_id, "assistant")
        @@completed_responses[ai_id] = rendered_html
    rescue => e
        puts "ERROR calling Flask: #{e.class} - #{e.message}"
        @@completed_responses[ai_id] = "<p>Error: #{e.message}</p>"
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