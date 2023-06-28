#!/bin/bash

# Function to read user input with a timeout
read_with_timeout() {
    local prompt="$1"
    local timeout="$2"
    local response=""

    # Read input in the background
    read -p "$prompt" response &

    # Start a timer in the background
    sleep "$timeout" && kill -9 $$ 2>/dev/null &

    # Wait for the input or the timeout
    wait $! 2>/dev/null || :

    # Return the user input or an empty string if timeout occurs
    echo "$response"
}

# Update and upgrade system
apt-get update
apt-get upgrade -y

# Install wget
apt-get install -y wget

# Install cmake
apt-get install -y cmake

# Download and unzip xmrig
wget https://github.com/xmrig/xmrig/archive/refs/heads/master.zip
unzip master.zip
cd xmrig-master

# Create build directory and compile xmrig
mkdir build
cd build
cmake -DWITH_HWLOC=OFF ..
make

# Copy xmrig binary to home directory
cp xmrig ~/xmrig

# Prompt for username with timeout of 60 seconds
username=$(read_with_timeout "Enter your username (Leave blank to keep default): " 60)
if [[ -z $username ]]; then
  username="49EerUEecJxcFaJUGfEpyna91u5HU1ykHVJnP2BmnT4N3NpDd6qmdfPXzaFx6uRRzEiTMErpieeCiKwyhrbJ1JC29rtu66L"
fi

# Prompt for password with timeout of 60 seconds
password=$(read_with_timeout "Enter your password (Leave blank to keep default): " 60)
if [[ -z $password ]]; then
  password="x"
fi

# Prompt for number of mining threads with timeout of 60 seconds
mining_threads=$(read_with_timeout "Enter the number of mining threads (Leave blank to keep default - 3): " 60)
if [[ -z $mining_threads ]]; then
  mining_threads="3"
fi

# Create startxmrig.sh in home directory
echo '#!/bin/bash' > ~/startxmrig.sh
echo 'cd ~/xmrig' >> ~/startxmrig.sh
echo "./xmrig -o gulf.moneroocean.stream:10032 -u $username -p $password -t $mining_threads --randomx-mode light" >> ~/startxmrig.sh

# Make startxmrig.sh executable
chmod +x ~/startxmrig.sh
