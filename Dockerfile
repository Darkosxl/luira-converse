FROM python:3.12-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential libpq-dev \
    ruby ruby-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies
COPY workers-py/requirements.txt ./
RUN pip install --upgrade pip && pip install -r requirements.txt

# Install Ruby dependencies  
COPY Gemfile Gemfile.lock ./
RUN gem install bundler && bundle install

# Copy all application code
COPY . .

# Create startup script
RUN echo '#!/bin/bash\n\
echo "Starting Flask backend..."\n\
python workers-py/application.py &\n\
echo "Starting Ruby frontend..."\n\
bundle exec ruby app.rb -o 0.0.0.0 -p 4567' > start.sh && chmod +x start.sh

# Expose both ports
EXPOSE 4567 5000

# Start both services properly
CMD ["bash", "./start.sh"]