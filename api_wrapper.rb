require 'net/http'
require 'json'

class APIWrapper
  BASE_URL = 'https://api.example.com'

  def initialize(api_token = nil)
    @api_token = api_token
  end

  def self.create_endpoint(name, http_method:, path_template:)
    define_method(name) do |params = {}|
      # Replace placeholders in the path with actual parameters
      path = path_template.gsub(/:\w+/) do |match|
        key = match[1..-1].to_sym
        value = params.delete(key) || raise(ArgumentError, "Missing required parameter: #{key}")
        URI.encode_www_form_component(value)
      end

      uri = URI(BASE_URL + path)

      # For GET requests, append remaining params as query parameters
      if http_method == :get && !params.empty?
        uri.query = URI.encode_www_form(params)
      end

      # Create the HTTP request object
      request = case http_method
                when :get
                  Net::HTTP::Get.new(uri)
                when :post
                  req = Net::HTTP::Post.new(uri)
                  req.body = params.to_json
                  req.content_type = 'application/json'
                  req
                when :put
                  req = Net::HTTP::Put.new(uri)
                  req.body = params.to_json
                  req.content_type = 'application/json'
                  req
                when :delete
                  Net::HTTP::Delete.new(uri)
                else
                  raise ArgumentError, "Unsupported HTTP method: #{http_method}"
                end

      # Add authentication header if token is provided
      request['Authorization'] = "Bearer #{@api_token}" if @api_token

      # Perform the HTTP request
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(request)
      end

      # Handle response codes
      case response.code.to_i
      when 200..299
        JSON.parse(response.body) unless response.body.strip.empty?
      when 400..499
        raise "Client Error #{response.code}: #{response.message} - #{response.body}"
      when 500..599
        raise "Server Error #{response.code}: #{response.message}"
      else
        raise "Unexpected Response #{response.code}: #{response.message}"
      end
    end
  end

  # Dynamically define API endpoints
  create_endpoint :get_user, http_method: :get, path_template: '/users/:id'
  create_endpoint :create_user, http_method: :post, path_template: '/users'
  create_endpoint :update_user, http_method: :put, path_template: '/users/:id'
  create_endpoint :delete_user, http_method: :delete, path_template: '/users/:id'
  create_endpoint :list_users, http_method: :get, path_template: '/users'
end

# Usage examples:

# Initialize the API wrapper with an optional API token for authentication
api = APIWrapper.new('your_api_token_here')

# Get user with ID 1
begin
  user = api.get_user(id: 1)
  puts "User Details: #{user}"
rescue => e
  puts "Error: #{e.message}"
end

# Create a new user
begin
  new_user = api.create_user(name: 'John Doe', email: 'john@example.com')
  puts "Created User: #{new_user}"
rescue => e
  puts "Error: #{e.message}"
end

# Update an existing user
begin
  updated_user = api.update_user(id: 1, name: 'Jane Doe', email: 'jane@example.com')
  puts "Updated User: #{updated_user}"
rescue => e
  puts "Error: #{e.message}"
end

# Delete a user
begin
  response = api.delete_user(id: 1)
  puts "Delete Response: #{response}"
rescue => e
  puts "Error: #{e.message}"
end

# List users with optional query parameters
begin
  users = api.list_users(page: 2, per_page: 10)
  puts "User List: #{users}"
rescue => e
  puts "Error: #{e.message}"
end
