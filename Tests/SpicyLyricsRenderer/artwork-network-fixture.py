"""Loopback-only artwork responses with and without cross-origin permission."""
from http.server import BaseHTTPRequestHandler, HTTPServer

ART = b'<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><path fill="#cc3333" d="M0 0h32v64H0z"/><path fill="#3366cc" d="M32 0h32v64H32z"/></svg>'


class ArtworkHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ('/cors.svg', '/opaque.svg'):
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'image/svg+xml')
        self.send_header('Content-Length', str(len(ART)))
        if self.path == '/cors.svg':
            self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(ART)


server = HTTPServer(('127.0.0.1', 0), ArtworkHandler)
print(f'ARTWORK_ORIGIN=http://127.0.0.1:{server.server_port}', flush=True)
server.serve_forever()
