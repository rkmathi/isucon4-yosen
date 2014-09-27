#
# Install additional middleware
#

include_recipe "./recipes/redis.rb"


#
# Main deploy script
#

git "/home/isucon/webapp" do
  repository "git@github.com:rkmathi/isucon4-yosen"
  user "isucon"
end

execute("supervisorctl restart isucon_ruby")
