FROM ruby:3.2-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy Ruby dependencies
COPY Gemfile Gemfile.lock ./

# Install Ruby gems
RUN gem install bundler && bundle install

# Copy application code (exclude workers-py)
COPY app.rb ./
COPY models/ ./models/
COPY views/ ./views/
COPY public/ ./public/

# Expose Ruby/Sinatra port
EXPOSE 4567

# Start Ruby application
CMD ["bundle", "exec", "ruby", "app.rb", "-o", "0.0.0.0", "-p", "4567"]