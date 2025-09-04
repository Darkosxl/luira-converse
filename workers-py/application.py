# application.py
import os
import logging
import math
import uuid # For generating unique session IDs
import json # Import json for safe logging if needed
from datetime import datetime
from flask_cors import CORS
from VC_chain_logic import (get_assistant_response) 
from flask import Flask, render_template, request, jsonify, session
from VC_chain_database import get_chat_history
from sqlalchemy import text
from VC_chain_tools import get_available_sectors, get_available_subsectors


log = logging.getLogger(__name__)
logging.basicConfig(
    level=logging.INFO,  # Adjust level (DEBUG, INFO, WARNING, ERROR) as needed
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

application = Flask(__name__)
application.config['SECRET_KEY'] = os.environ.get('FLASK_SECRET_KEY', 'change-this-to-a-strong-random-secret-key-in-prod') # Added note
if application.config['SECRET_KEY'] == 'change-this-to-a-strong-random-secret-key-in-prod':
    log.warning("Using default Flask SECRET_KEY. Please set a secure key in production environment.")

# Alias for gunicorn compatibility (gunicorn expects 'app' by default)
app = application


log.info("Flask app initialized.")


# ===========================================================
#                 Flask Routes
# ===========================================================

@application.route('/')
def index():
    """Render the main chat page."""
    # Initialize Flask session ID if it doesn't exist
    if 'session_id' not in session:
        session['session_id'] = str(uuid.uuid4())
        log.info(f"New Flask session created: {session['session_id']}")
    else:
        log.debug(f"Existing Flask session found: {session['session_id']}")
    # Renders the template named 'index.html' from the 'templates' folder
    return render_template('index.html')

@application.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint for service discovery."""
    return jsonify({
        "status": "healthy",
        "service": "capmap-backend",
        "version": "2.1.13",
        "timestamp": datetime.utcnow().isoformat(),
        "endpoints": ["/chat", "/api/vote", "/api/sectors", "/api/history"]
    }), 200


# TODO SIMPLIFY THIS + MOVE THE LOGIC TO HANDLE THE RESPONSE TO THE FRONTEND
@application.route('/chat_capmap', methods=['POST'])
def chat():
    """Handle incoming chat messages from the user."""
    session_id = session.setdefault('session_id', str(uuid.uuid4()))
    request_id = str(uuid.uuid4())
    log.info(f"[ReqID: {request_id}] Received chat request for session {session_id}")
    
    try:
        data = request.get_json()
        if not data or 'message' not in data:
            return jsonify({"reply": "Invalid request format. 'message' key is missing.", "options_data": None}), 400

        # Safely extract user message from either a string or a rich object
        raw_msg = data.get("message", "")
        if isinstance(raw_msg, dict):
            user_message = raw_msg.get("content") or raw_msg.get("text") or ""
        else:
            user_message = str(raw_msg)

        user_message = user_message.strip()
        if not user_message:
            return jsonify({"reply": "Please type a message!", "options_data": None})

        general_agent_check = data.get('general_agent_check', False)
        chat_history = get_chat_history(session_id, 20)
        
        log.info(f"[ReqID: {request_id}] Processing message for session {session_id}: '{user_message}'")
        response_text = get_assistant_response(user_message, session_id, general_agent_check, chat_history)
        return jsonify({"reply": response_text, "options_data": None}), 200

    except Exception as e:
        log.exception(f"!!! [ReqID: {request_id}] Unhandled ERROR during /chat for session {session_id}: {e}")
        return jsonify({"reply": "Sorry, an unexpected internal error occurred while processing your request.", "options_data": None}), 500

@application.route('/chat-stream', methods=['POST'])
def chat_stream():
    """Stream chat responses with real-time status updates"""
    import time
    from flask import Response
    
    # Ensure session is set up
    if 'session_id' not in session:
        session['session_id'] = str(uuid.uuid4())
    
    session_id = session['session_id']
    request_id = str(uuid.uuid4())
    # Parse request data BEFORE starting the generator to avoid using
    # Flask's request context inside the streaming generator.
    try:
        data = request.get_json(silent=True) or {}
    except Exception as e:
        log.exception(f"Error reading JSON in /chat-stream: {e}")
        error_body = f"data: {json.dumps({'type': 'error', 'message': 'Invalid JSON payload'})}\n\n"
        return Response(error_body, mimetype='text/plain')

    # Validate and normalize inputs
    if 'message' not in data:
        error_body = f"data: {json.dumps({'type': 'error', 'message': 'No message field'})}\n\n"
        return Response(error_body, mimetype='text/plain')

    raw_msg = data.get("message", "")
    if isinstance(raw_msg, dict):
        user_message = raw_msg.get("content") or raw_msg.get("text") or ""
    else:
        user_message = str(raw_msg)

    user_message = user_message.strip()
    if not user_message:
        error_body = f"data: {json.dumps({'type': 'error', 'message': 'Please type a message!'})}\n\n"
        return Response(error_body, mimetype='text/plain')

    general_agent_check = data.get('general_agent_check', False)
    chat_history = data.get('chat_history', [])

    def generate():
        try:
            # Send status updates with realistic timing
            yield f"data: {json.dumps({'type': 'status', 'message': 'Analyzing your query...'})}\n\n"
            time.sleep(0.3)
            
            yield f"data: {json.dumps({'type': 'status', 'message': 'Routing to appropriate agent...'})}\n\n"
            time.sleep(0.4)
            
            yield f"data: {json.dumps({'type': 'status', 'message': 'Processing with AI models...'})}\n\n"
            time.sleep(0.5)
            
            yield f"data: {json.dumps({'type': 'status', 'message': 'Querying database...'})}\n\n"
            time.sleep(0.4)
            
            yield f"data: {json.dumps({'type': 'status', 'message': 'Generating response...'})}\n\n"
            
            # Get actual response
            log.info(f"[ReqID: {request_id}] Processing streaming message for session {session_id}: '{user_message}'")
            response_text = get_assistant_response(user_message, session_id, general_agent_check, chat_history)
            
            # Send final response
            yield f"data: {json.dumps({'type': 'response', 'message': response_text})}\n\n"
            
        except Exception as e:
            log.exception(f"Error in chat_stream: {e}")
            yield f"data: {json.dumps({'type': 'error', 'message': 'Internal server error'})}\n\n"

    return Response(generate(), mimetype='text/plain')

@application.route('/get_options', methods=['GET'])
def get_options():
    """Endpoint to fetch paginated lists of options (e.g., subsectors)."""
    return jsonify(None), 200

@application.route('/api/history', methods=['GET'])
def history():
    """Endpoint to fetch chat history for the current session."""
    # Ensure session exists
    if 'session_id' not in session:
        log.warning("History request received without a Flask session_id")
        return jsonify([]), 200  # Return empty array if no session
    
    session_id = session['session_id']
    limit = int(request.args.get('limit', 20))
    
    log.info(f"Fetching history for session {session_id} with limit {limit}")
    
    try:
        history_data = get_chat_history(session_id, limit)
        return jsonify(history_data), 200
    except Exception as e:
        log.error(f"Error in /api/history endpoint: {e}")
        return jsonify([]), 500


@application.route('/api/vote', methods=['GET', 'PATCH'])
def api_vote():
    """Handle voting on messages - proxy functionality for frontend compatibility."""
    if request.method == 'GET':
        chat_id = request.args.get('chatId')
        if not chat_id:
            return jsonify({"error": "Parameter chatId is required"}), 400
        
        # For now, return empty votes array - can be expanded later
        log.info(f"Fetching votes for chat {chat_id}")
        return jsonify([]), 200
    
    elif request.method == 'PATCH':
        try:
            data = request.get_json()
            chat_id = data.get('chatId')
            message_id = data.get('messageId')
            vote_type = data.get('type')
            
            if not all([chat_id, message_id, vote_type]):
                return jsonify({"error": "Parameters chatId, messageId, and type are required"}), 400
            
            # Log the vote for now - can be expanded to store in database later
            log.info(f"Vote received: chat={chat_id}, message={message_id}, type={vote_type}")
            
            return jsonify({"message": "Message voted"}), 200
        except Exception as e:
            log.error(f"Error processing vote: {e}")
            return jsonify({"error": "Failed to process vote"}), 500

@application.route('/api/sectors', methods=['GET'])
def api_sectors():
    """Handle sectors and subsectors requests with type parameter - matching frontend API."""
    sector_type = request.args.get('type')
    
    if not sector_type or sector_type not in ['sectors', 'subsectors']:
        return jsonify({"error": 'Invalid type parameter. Must be "sectors" or "subsectors"'}), 400
    
    try:
        if sector_type == 'sectors':
            log.info("Fetching available sectors via /api/sectors")
            query = text('SELECT DISTINCT "Sector" FROM vc_sector_based_raw WHERE "Sector" IS NOT NULL ORDER BY "Sector"')
            
            with engine.connect() as conn:
                result = conn.execute(query)
                rows = result.fetchall()
                sector_list = [row[0] for row in rows if row[0]]
            
            return jsonify({"sectors": sector_list}), 200
        else:
            log.info("Fetching available subsectors via /api/sectors")
            query = text("""
            WITH sectors_exploded as (
                SELECT TRIM(sector_split.value) AS sector 
                FROM funding_rounds fr 
                CROSS JOIN LATERAL string_to_array(COALESCE(fr."Sectors", ''), ',') AS sector_split(value) 
                WHERE TRIM(sector_split.value) <> '' 
                AND TRIM(sector_split.value) <> '#NAME? ()'
            )
            SELECT DISTINCT sector
            FROM sectors_exploded
            WHERE sector IS NOT NULL
            ORDER BY sector
            """)
            
            with engine.connect() as conn:
                result = conn.execute(query)
                rows = result.fetchall()
                subsector_list = [row[0] for row in rows if row[0]]
            
            return jsonify({"subsectors": subsector_list}), 200
    except Exception as e:
        log.error(f"Error fetching {sector_type}: {e}")
        return jsonify({"error": f"Failed to fetch {sector_type}"}), 500


# ===========================================================
#                 Run the Flask App
# ===========================================================

# Configure CORS for production
ALLOWED_ORIGINS = [
    "https://capmapai.com",
    "https://ai.capmapai.com",
    "https://www.capmapai.com",
    "http://localhost:4567",  # Development
]

CORS(application, origins=ALLOWED_ORIGINS, supports_credentials=True)

if __name__ == '__main__':
    # This is only used for development
    application.run(host='0.0.0.0', port=5000, debug=False) 
