def production?
  ENV["RACK_ENV"] == "production"
end

def development?
  !production?
end

require 'sinatra/base'
require 'digest/sha2'
require 'mysql2-cs-bind'
require 'rack-flash'
require 'json'
require 'slim'
require 'redis'
require 'singleton'

if development?
  require 'rack-lineprof'
end

class FragmentStore
  include Singleton

  def cache(key, &block)
    cached = redis.get(key)
    if cached
      Marshal.load(cached)
    else
      update(key, block.call)
    end
  end

  def update(key, value)
    redis.set(key, Marshal.dump(value))
    value
  end

  def purge(key)
    redis.del(key)
  end

  def increment(key)
    redis.incr(key)
  end

  def atomic_increment(key)
    begin
      result = redis.watch(key) do
        if block_given?
          val = redis.get(key).to_i
          if yield(val)
            redis.multi do |m|
              m.incr(key)
            end
          else
            true
          end
        else
          redis.multi do |m|
            m.incr(key)
          end
        end
      end
    end while !result
    result.is_a?(Array) ? result.first : false
  end

  def decrement(key)
    redis.decr(key)
  end

  def redis
    @redis ||= Redis.new(host: '127.0.0.1', db: 0)
  end
end

class UserStore
  include Singleton

  def login(user: nil, password: nil)
    h = find_by_user(user)
    return nil unless h
    if Digest::SHA256.hexdigest("#{password}:#{h[:salt]}") == h[:hash]
      return h.merge(login: true)
    else
      return h.merge(login: false)
    end
  end

  def find_by_user(user)
    val = redis.get(user)
    return nil unless val
    id, pwh, salt = val.split(':')
    {
      id: id,
      user: user,
      hash: pwh,
      salt: salt,
    }
  end

  def set(id: nil, user: nil, hash: nil, salt: nil)
    redis.set(user, "#{id}:#{hash}:#{salt}")
  end

  def redis
    @redis ||= Redis.new(host: '127.0.0.1', db: 1)
  end
end

module Isucon4
  class App < Sinatra::Base
    use Rack::Session::Cookie, secret: ENV['ISU4_SESSION_SECRET'] || 'shirokane'
    use Rack::Flash
    set :public_folder, File.expand_path('../../public', __FILE__)

    if development?
      use Rack::Lineprof, profile: "app.rb"
    end

    helpers do
      def config
        @config ||= {
          user_lock_threshold: (ENV['ISU4_USER_LOCK_THRESHOLD'] || 3).to_i,
          ip_ban_threshold: (ENV['ISU4_IP_BAN_THRESHOLD'] || 10).to_i,
        }
      end

      def db
        Thread.current[:isu4_db] ||= Mysql2::Client.new(
          host: ENV['ISU4_DB_HOST'] || 'localhost',
          port: ENV['ISU4_DB_PORT'] ? ENV['ISU4_DB_PORT'].to_i : nil,
          username: ENV['ISU4_DB_USER'] || 'root',
          password: ENV['ISU4_DB_PASSWORD'],
          database: ENV['ISU4_DB_NAME'] || 'isu4_qualifier',
          reconnect: true,
        )
      end

      def calculate_password_hash(password, salt)
        Digest::SHA256.hexdigest "#{password}:#{salt}"
      end

      def login_log(succeeded, login, user_id = nil)
        db.xquery("INSERT INTO login_log" \
                  " (`created_at`, `user_id`, `login`, `ip`, `succeeded`)" \
                  " VALUES (?,?,?,?,?)",
                 Time.now, user_id, login, request.ip, succeeded ? 1 : 0)

        if user_id
          cache_key = "user_locked_status_#{user_id}"
          if succeeded
            fragment_store.redis.set(cache_key, 0)
          else
            fragment_store.atomic_increment(cache_key)
          end
        end

        ip_str = request.ip.gsub('.', '_')
        ip_cache_key = "ip_ban_#{ip_str}"
        if succeeded
          fragment_store.redis.set(ip_cache_key, 0)
        else
          fragment_store.atomic_increment(ip_cache_key)
        end

        fragment_store.purge("last_login_#{user_id}")
        fragment_store.purge("user_locked_#{user_id}")
      end

      def user_locked?(user)
        return nil unless user

        lock = fragment_store.redis.get("user_locked_status_#{user[:id]}").to_i

        #log = fragment_store.cache("user_locked_#{user['id']}") do
        #  db.xquery("SELECT COUNT(1) AS failures FROM login_log WHERE user_id = ? AND id > IFNULL((select id from login_log where user_id = ? AND succeeded = 1 ORDER BY id DESC LIMIT 1), 0);", user['id'], user['id']).first
        #end

        config[:user_lock_threshold] <= lock
      end

      def ip_banned?
        ip_str = request.ip.gsub('.', '_')
        ban = fragment_store.redis.get("ip_ban_#{ip_str}").to_i
        #log = db.xquery("SELECT COUNT(1) AS failures FROM login_log WHERE ip = ? AND id > IFNULL((select id from login_log where ip = ? AND succeeded = 1 ORDER BY id DESC LIMIT 1), 0);", request.ip, request.ip).first

        config[:ip_ban_threshold] <= ban #log['failures']
      end

      def attempt_login(login, password)
        user = user_store.login(user: login, password: password)

        if ip_banned?
          login_log(false, login, user ? user[:id] : nil)
          return [nil, :banned]
        end

        if user_locked?(user)
          login_log(false, login, user[:id])
          return [nil, :locked]
        end

        if user && user[:login]
          login_log(true, login, user[:id])
          [user, nil]
        elsif user
          login_log(false, login, user[:id])
          [nil, :wrong_password]
        else
          login_log(false, login)
          [nil, :wrong_login]
        end
      end

      def current_user
        return @current_user if @current_user
        return nil unless session[:user]

        @current_user = user_store.find_by_user(session[:user])

        unless @current_user
          session[:user] = nil
          return nil
        end

        @current_user
      end

      def last_login
        return nil unless current_user

        @last_login ||= fragment_store.cache("last_login_#{current_user[:id]}") do
          db.xquery('SELECT * FROM login_log WHERE succeeded = 1 AND user_id = ? ORDER BY id DESC LIMIT 2', current_user[:id]).each.last
        end
      end

      def banned_ips
        ips = []
        threshold = config[:ip_ban_threshold]

        not_succeeded = db.xquery('SELECT ip FROM (SELECT ip, MAX(succeeded) as max_succeeded, COUNT(1) as cnt FROM login_log GROUP BY ip) AS t0 WHERE t0.max_succeeded = 0 AND t0.cnt >= ?', threshold)

        ips.concat not_succeeded.each.map { |r| r['ip'] }

        last_succeeds = db.xquery(<<-EOS)
          SELECT login_log.ip AS ip, COUNT(login_log.id) AS count
          FROM login_log, (SELECT ip, MAX(id) AS last_login_id FROM login_log WHERE succeeded = 1 GROUP BY ip) AS t
          WHERE t.ip = login_log.ip AND t.last_login_id < login_log.id
          GROUP BY login_log.ip
        EOS

        last_succeeds.each do |row|
          if threshold <= row['count']
            ips << row['ip']
          end
        end

        ips
      end

      def locked_users
        user_ids = []
        threshold = config[:user_lock_threshold]

        not_succeeded = db.xquery('SELECT user_id, login FROM (SELECT user_id, login, MAX(succeeded) as max_succeeded, COUNT(1) as cnt FROM login_log GROUP BY user_id) AS t0 WHERE t0.user_id IS NOT NULL AND t0.max_succeeded = 0 AND t0.cnt >= ?', threshold)

        user_ids.concat not_succeeded.each.map { |r| r['login'] }

        last_succeeds = db.xquery(<<-EOS)
          SELECT t.user_id, t.login, t.last_login_id, count(login_log.user_id) AS count
          FROM login_log, (SELECT user_id, login, MAX(id) AS last_login_id FROM login_log WHERE user_id IS NOT NULL AND succeeded = 1 GROUP BY user_id) AS t
          WHERE login_log.user_id = t.user_id AND t.last_login_id < login_log.id
          GROUP BY login_log.user_id
        EOS

        last_succeeds.each do |row|
          if threshold <= row['count']
            user_ids << row['login']
          end
        end

        user_ids
      end

      def fragment_store
        @fragment_store ||= FragmentStore.instance
      end

      def user_store
        @user_store ||= UserStore.instance
      end
    end

    get '/' do
      slim :index
    end

    post '/login' do
      user, err = attempt_login(params[:login], params[:password])
      unless err
        session[:user] = user[:user]
        redirect '/mypage'
      else
        case err
        when :locked
          flash[:notice] = "This account is locked."
        when :banned
          flash[:notice] = "You're banned."
        else
          flash[:notice] = "Wrong username or password"
        end
        redirect "/?flash_msg=#{err}"
      end
    end

    get '/mypage' do
      unless current_user
        flash[:notice] = "You must be logged in"
        redirect "/?flash_msg=you_must_be_logged_in"
      end
      slim :mypage
    end

    get '/initializer' do
      all_users = db.xquery('SELECT * FROM users')
      all_users.each do |user|
        user_store.set(
          id: user['id'],
          user: user['login'],
          hash: user['password_hash'],
          salt: user['salt']
        )
      end

      "OK"
    end

    get '/report' do
      content_type :json
      {
        banned_ips: banned_ips,
        locked_users: locked_users,
      }.to_json
    end

    run! if development?
  end
end
