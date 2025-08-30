require 'sinatra'
require 'erb'
require 'ruby_llm'
require 'dotenv'
require 'sinatra/sse'
require 'date'
require 'redcarpet'
require_relative 'models/stream'
require_relative 'models/database'



class SinatraRouter < Sinatra::Base
    enable :sessions
    
    before do
        @chat_stream_service = ChatStreamService.new()
        @database = Database.new()
    end
    get '/' do
       erb :'landing-page'
    end
    get '/chat' do
        @show_welcome = session[:first_visit] != false
        @left_sidebar_open = session[:left_sidebar_open] || false
        @right_sidebar_open = session[:right_sidebar_open] || false
        @expanded_sections = session[:expanded_sections] || {}
        erb :'chat'
    end
    post '/chat/messages' do
        user_message = params[:message]
        
        # Mark that user has sent first message
        session[:first_visit] = false
        
        # Generate unique ID for this AI response
        ai_id = "ai-response-#{Time.now.to_f.to_s.gsub('.', '')}"
        
        # Return immediate user message display + start AI streaming
        user_html = erb :user_message, layout: false, locals: {message: user_message}
        ai_placeholder = "<div id=\"#{ai_id}\" class=\"flex justify-start mb-6\"><div class=\"flex items-start gap-3 max-w-2xl\"><div class=\"ai-avatar-container ai-loading\"><div class=\"w-8 h-8 bg-gray-800 rounded-full flex items-center justify-center text-white text-sm font-semibold flex-shrink-0 ai-avatar\">✨</div></div><div class=\"text-gray-900 flex-1 min-w-0 break-words\"><div class=\"typing-indicator\">AI is thinking...</div></div></div></div>"
        
        response.headers['Content-Type'] = 'text/html'
        "#{user_html}#{ai_placeholder}<script>startAIStream('#{user_message.gsub("'", "\\'")}', '#{ai_id}')</script>"
    end
    
    get '/chat/stream' do
        content_type 'text/event-stream'
        cache_control 'no-cache'
        
        user_message = params[:message]
        
        stream do |out|
            @chat_stream_service.call(user_message, out)
            out << "event: end\ndata: \n\n"
        end
    end
    
    # Sidebar toggle routes
    post '/toggle-left-sidebar' do
        session[:left_sidebar_open] = !session[:left_sidebar_open]
        @left_sidebar_open = session[:left_sidebar_open]
        
        content_type 'text/html'
        erb :sidebar, layout: false
    end
    
    post '/toggle-right-sidebar' do
        session[:right_sidebar_open] = !session[:right_sidebar_open]
        @right_sidebar_open = session[:right_sidebar_open]
        @expanded_sections = session[:expanded_sections] || {}
        
        content_type 'text/html'
        erb :_agent_sidebar, layout: false
    end
    
    post '/toggle-section/:section' do
        session[:expanded_sections] ||= {}
        section = params[:section]
        session[:expanded_sections][section] = !session[:expanded_sections][section]
        redirect '/chat'
    end
    
    post '/set-message' do
        # Just return empty - this is for the HTMX buttons to work
        ""
    end

    # Chat history routes
    get '/chat/history' do
        chats = @database.get_chats
        grouped_chats = group_chats_by_date(chats)
        
        content_type 'text/html'
        erb :chat_history, layout: false, locals: { grouped_chats: grouped_chats }
    end

    delete '/chat/:id' do
        chat_id = params[:id]
        @database.delete_chat_by_id(chat_id)
        
        # Return updated chat history
        chats = @database.get_chats
        grouped_chats = group_chats_by_date(chats)
        
        content_type 'text/html'
        erb :chat_history, layout: false, locals: { grouped_chats: grouped_chats }
    end

    get '/chat/:id' do
        chat_id = params[:id]
        @current_chat = @database.get_chat_by_id(chat_id)
        messages = @database.get_messages_by_chat_id(chat_id)
        
        # Set up session variables that the chat template expects
        @show_welcome = false
        @left_sidebar_open = session[:left_sidebar_open] || false
        @right_sidebar_open = session[:right_sidebar_open] || false
        @expanded_sections = session[:expanded_sections] || {}
        
        erb :chat, locals: { messages: messages }
    end

    private

    def group_chats_by_date(chats)
        now = Date.today
        
        grouped = {
            today: [],
            yesterday: [],
            last_week: [],
            last_month: [],
            older: []
        }
        
        chats.each do |chat|
            chat_date = Date.parse(chat[:createdAt].to_s)
            days_ago = (now - chat_date).to_i
            
            if days_ago == 0
                grouped[:today] << chat
            elsif days_ago == 1
                grouped[:yesterday] << chat
            elsif days_ago <= 7
                grouped[:last_week] << chat
            elsif days_ago <= 30
                grouped[:last_month] << chat
            else
                grouped[:older] << chat
            end
        end
        
        grouped
    end
    
end

def main
    SinatraRouter.run!
end

main