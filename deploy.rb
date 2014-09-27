git "/home/isucon/webapp" do
  repository "git@github.com:rkmathi/isucon4-yosen"
  user "isucon"
end

execute("cd /home/isucon/webapp/ruby; /home/isu-user/isucon2-ruby/config/env.sh bundle install")
execute("supervisorctl restart isucon_ruby")
