if ENV["LOCAL_DEPLOY"] == "true"
  system("rm -f app.tar; tar cvf app.tar deploy.rb bench.rb public ruby")

  execute("rm -rf /home/isucon/webapp")
  execute("mkdir /home/isucon/webapp")

  template "/home/isucon/webapp/app.tar" do
    action :create
    source "app.tar"
  end

  execute("cd /home/isucon/webapp; tar xvf /home/isucon/webapp/app.tar")
  execute("rm /home/isucon/webapp/app.tar")
  execute("mkdir -p /home/isucon/webapp/ruby/tmp")
  execute("mkdir -p /home/isucon/webapp/ruby/log")
else
  execute("mkdir -p /home/isucon/webapp_back")
  execute("zip -r /home/isucon/webapp_back/#{Time.now.to_i}.zip /home/isucon/webapp")
  execute("rm -rf /home/isucon/webapp")
  execute("mkdir -p /root/.ssh; cp /home/isucon/.ssh/id_rsa /root/.ssh")
  execute("cd /home/isucon; git clone --depth 1 git@github.com:rkmathi/isucon4-yosen /home/isucon/webapp")
end

execute("cd /home/isucon/webapp/ruby; /home/isucon/env.sh bundle install")
execute("supervisorctl restart isucon_ruby")
