require 'sinatra'
require 'erb'
require 'ruby_llm'
require 'dotenv'
require 'sinatra/sse'
require 'date'
require 'redcarpet'
require 'json'
require 'net/http'
require_relative 'models/stream'
require_relative 'models/database'
require_relative 'models/conversation'


class SinatraRouter < Sinatra::Base
    enable :sessions
    
    before do
        @database = Database.new()
        @conversation = ConversationHost.new()
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
    get '/chat/available_sectors' do
        content_type :json
        sectors = @database.get_available_sectors
        { sectors: sectors }.to_json
    end
    get '/chat/available_subsectors' do
        content_type :json
        subsectors = @database.get_available_subsectors
        { subsectors: subsectors }.to_json
    end
    #USER INITITATES CHAT, OR SENDS MESSAGES, THOSE GET SAVED, AND THEY CALL THE BACKEND TO GET THE AI RESPONSE
    post '/chat/messages' do
        user_message = params[:message]  
        chat_id = @database.update_or_create_chat("private", user_message, session[:current_chat_id])
        session[:current_chat_id] = chat_id
        session[:first_visit] = false

        ai_id = "ai-response-#{Time.now.to_f.to_s.gsub('.', '')}"
        
        Thread.new do
            @conversation.call_capmap(user_message, ai_id, chat_id)
        end

        user_html = erb :user_message, layout: false, locals: {message: user_message}
        ai_placeholder = "<div id=\"#{ai_id}\" class=\"flex justify-start mb-6\"><div class=\"flex items-start gap-3 max-w-2xl\"><div class=\"ai-avatar-container ai-loading\"><div class=\"w-8 h-8 bg-gray-800 rounded-full flex items-center justify-center text-white text-sm font-semibold flex-shrink-0 ai-avatar\">✨</div></div><div class=\"text-gray-900 flex-1 min-w-0 break-words\"><div class=\"typing-indicator\">AI is thinking...</div></div></div></div>"
        
        "#{user_html}#{ai_placeholder}"
    end
    # AI RESPONSE sent from backend TAKEN HERE, IT IS SAVED AND THEN STREAMED TO THE FRONTEND
    post '/chat/ai_response' do
        data = JSON.parse(request.body.read)
        ai_content = data['content']
        ai_id = data['ai_id'] 
        chat_id = data['chat_id']
        
        # Save AI message to database
        @database.update_or_create_chat("private", ai_content, chat_id, "assistant")
        
        # Return the script to start AI streaming with the pre-created response
        content_type 'text/html'
        "<script>startAIStream('#{ai_content.gsub("'", "\\'")}', '#{ai_id}')</script>"
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