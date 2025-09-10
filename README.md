1. Clone
3. Make file executable first (maybe needed):
   chmod +x setup_uv_jupyter.sh
4. Run it:
   bash setup_uv_jupyter.sh
6. Run localhost port forwarding in your local computer to access jupyter notebook:
   ssh -N -L 5000:localhost:5000 user@your-server
