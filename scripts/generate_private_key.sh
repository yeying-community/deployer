# Generate keyfile
openssl ecparam -genkey -name secp256k1 -out my_private_key.pem
# Extract 32 byte private key
openssl ec -in my_private_key.pem -outform DER | tail -c +8 | head -c 32| xxd -p -c 32
