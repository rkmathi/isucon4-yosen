git "/home/isucon/webapp" do
  repository "git@github.com:rkmathi/isucon4-yosen"
  user "isucon"
end

execute("cd /home/isucon/webapp/ruby; /home/isucon/env.sh bundle install")
execute("supervisorctl restart isucon_ruby")
