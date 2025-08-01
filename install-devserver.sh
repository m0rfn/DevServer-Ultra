#!/bin/bash
set -e

REPO_URL="https://github.com/m0rfn/DevServer-Ultra.git"
BASE_DIR="$HOME/DevServer"
BREW_BIN="/opt/homebrew/bin"

echo "=== DevServer Ultra Installer (WebSocket + Autostart) ==="

# Detect OS
OS=""
if [[ "$OSTYPE" == "darwin"* ]]; then
  OS="macos"
elif [[ -f /etc/lsb-release || -f /etc/debian_version ]]; then
  OS="ubuntu"
else
  echo "Unsupported OS (only macOS or Ubuntu supported)."
  exit 1
fi

# Install dependencies
if [ "$OS" == "macos" ]; then
  if ! command -v brew &>/dev/null; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  $BREW_BIN/brew install php@7.4 php@8.2 nginx composer node redis mysql mailhog git
else
  sudo apt update
  sudo apt install -y nginx mysql-server redis-server php7.4 php7.4-fpm php7.4-cli php7.4-mysql \
  php8.2 php8.2-fpm php8.2-cli composer nodejs npm git unzip curl docker.io docker-compose
fi

# Clone or update repo
if [ -d "$BASE_DIR" ]; then
  cd "$BASE_DIR" && git pull
else
  git clone "$REPO_URL" "$BASE_DIR"
fi

mkdir -p "$BASE_DIR/conf" "$BASE_DIR/www" "$BASE_DIR/tools" "$BASE_DIR/websocket"

# Copy default configs
cp -n "$BASE_DIR/conf-samples/nginx.conf" "$BASE_DIR/conf/nginx.conf"
cp -n "$BASE_DIR/conf-samples/php74.ini" "$BASE_DIR/conf/php74.ini"
cp -n "$BASE_DIR/conf-samples/php82.ini" "$BASE_DIR/conf/php82.ini"
cp -n "$BASE_DIR/conf-samples/php-fpm-74.conf" "$BASE_DIR/conf/php-fpm-74.conf"
cp -n "$BASE_DIR/conf-samples/php-fpm-82.conf" "$BASE_DIR/conf/php-fpm-82.conf"

[ ! -f "$BASE_DIR/www/index.php" ] && echo "<?php echo '<h1>'.phpversion().'</h1>'; phpinfo();" > "$BASE_DIR/www/index.php"

# Setup Dashboard
cd "$BASE_DIR/dashboard"
composer install --no-interaction --prefer-dist
php -r "require 'auth.php'; update_password('admin','Morfn@2025'); echo \"Admin user created\n\";"

# Assets
mkdir -p "$BASE_DIR/dashboard/assets"
curl -fsSL https://cdn.jsdelivr.net/npm/sweetalert2@11/dist/sweetalert2.min.js -o "$BASE_DIR/dashboard/assets/sweetalert2.min.js"
curl -fsSL https://cdn.jsdelivr.net/npm/sweetalert2@11/dist/sweetalert2.min.css -o "$BASE_DIR/dashboard/assets/sweetalert2.min.css"
curl -fsSL https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css -o "$BASE_DIR/dashboard/assets/fontawesome.min.css"

# WebSocket
cd "$BASE_DIR/websocket"
cat > server.js <<'EOF'
const { Server } = require("socket.io");
const http = require("http");
const fs = require("fs");
const server = http.createServer();
const io = new Server(server,{cors:{origin:"*"}});
io.on("connection", socket=>console.log("Client connected:",socket.id));
server.listen(9000,()=>console.log("WebSocket on 9000"));

const queue = process.env.HOME+"/DevServer/ws_queue.json";
fs.writeFileSync(queue,"");
setInterval(()=>{
  if(fs.existsSync(queue)){
    const data = fs.readFileSync(queue,'utf8').trim();
    if(data){
      const lines = data.split("\n").filter(l=>l);
      fs.writeFileSync(queue,"");
      for(const line of lines){
        try{ const obj=JSON.parse(line); io.emit(obj.event,obj.data);}catch(e){}
      }
    }
  }
},1000);
EOF

cat > package.json <<'EOF'
{
  "name": "devserver-websocket",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": {
    "socket.io": "^4.7.2"
  }
}
EOF

npm install --production
touch "$BASE_DIR/ws_queue.json"

# Autostart for WebSocket
if [ "$OS" == "macos" ]; then
  PLIST="$HOME/Library/LaunchAgents/com.devserver.websocket.plist"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.devserver.websocket</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/env</string>
    <string>node</string>
    <string>$BASE_DIR/websocket/server.js</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/tmp/devserver_ws.log</string>
  <key>StandardErrorPath</key><string>/tmp/devserver_ws.log</string>
</dict>
</plist>
EOF
  launchctl load "$PLIST"
  launchctl start com.devserver.websocket
else
  WS_SERVICE=/etc/systemd/system/devserver-ws.service
  sudo bash -c "cat > $WS_SERVICE" <<EOF
[Unit]
Description=DevServer WebSocket Service
After=network.target

[Service]
ExecStart=/usr/bin/node $BASE_DIR/websocket/server.js
Restart=always
User=root
WorkingDirectory=$BASE_DIR/websocket

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable devserver-ws
  sudo systemctl start devserver-ws
fi

echo "Installation complete!"
php -S 127.0.0.1:9999 -t "$BASE_DIR/dashboard"
