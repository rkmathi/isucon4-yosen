git "/home/isucon/webapp" do
  repository "git@github.com:rkmathi/isucon4-yosen"
  user "isucon"
end

execute("supervisorctl restart isucon_ruby")
