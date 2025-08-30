require 'sinatra'
require 'erb'
require 'ruby_llm'
require 'dotenv'
require 'sinatra/sse'
require_relative 'models/stream'



class SinatraRouter < Sinatra::Base
    before do
        @chat_stream_service = ChatStreamService.new()
    end
    get '/' do
       erb :'landing-page'
    end
    get '/chat' do
        erb :'chat'
    end
    post '/chat/messages' do
        user_message = params[:message]
        
        # Generate unique ID for this AI response
        ai_id = "ai-response-#{Time.now.to_f.to_s.gsub('.', '')}"
        
        # Return immediate user message display + start AI streaming
        user_html = erb :user_message, layout: false, locals: {message: user_message}
        ai_placeholder = "<div id=\"#{ai_id}\" class=\"flex justify-start mb-6\"><div class=\"flex items-start gap-3 max-w-2xl\"><div class=\"w-8 h-8 bg-orange-500 rounded-full flex items-center justify-center text-white text-sm font-semibold flex-shrink-0 mt-1\"></div><div class=\"bg-gray-50 p-4 rounded-2xl rounded-tl-md\"><div class=\"typing-indicator\">AI is thinking...</div></div></div></div>"
        
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
    
end

def main
    SinatraRouter.run!
end

main