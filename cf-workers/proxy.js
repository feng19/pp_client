import { connect } from "cloudflare:sockets";

// Keepalive: client and proxy exchange an application-level ping/pong every 80s
// so an idle tunnel is not reaped by an intermediary, and a peer that vanished
// is noticed on the next tick. Text frames are the control channel — tunnel
// data only ever rides binary frames — so a ping/pong is never relayed into
// the target.
const PING_INTERVAL = 60_000;
const PING = "pp-ping";
const PONG = "pp-pong";

export default {
  async fetch(request) {
    const TOKEN =
      "+Ud0vzqdpt1YeXIMGZsjXaVwJiyLQgW7DNc6UxuwjtSAhCtzbeSnO/EERdE/Vf/o";

    if (request.headers.get("Authorization") !== TOKEN)
      return new Response("Unauthorized", { status: 401 });

    const upgradeHeader = request.headers.get("Upgrade");

    if (!upgradeHeader || upgradeHeader !== "websocket")
      return new Response("Expected Upgrade: websocket", { status: 426 });

    try {
      const target_list = request.headers.get("X-Proxy-Target").split(":");
      const target = connect({
        hostname: target_list[0],
        port: target_list[1],
      });
      const writer = target.writable.getWriter();
      const websocket = new WebSocketPair();
      const [client, server] = Object.values(websocket);

      server.accept();

      server.addEventListener("message", (e) => {
        // Application-level ping/pong — never relayed into the target.
        if (e.data === PING) {
          server.send(PONG);
          return;
        }
        if (e.data === PONG) return;

        writer.write(e.data);
      });

      // Ping the client every 80s. The pong it answers with comes from its own
      // code, so it proves the client end of the tunnel is alive too.
      const pingTimer = setInterval(() => {
        try {
          server.send(PING);
        } catch {
          clearInterval(pingTimer);
        }
      }, PING_INTERVAL);

      server.addEventListener("close", () => clearInterval(pingTimer));

      target.readable.pipeTo(
        new WritableStream({
          write(chunk) {
            server.send(chunk);
          },
        })
      );

      return new Response(null, { status: 101, webSocket: client });
    } catch (e) {
      return new Response(e, { status: 500 });
    }
  },
};
