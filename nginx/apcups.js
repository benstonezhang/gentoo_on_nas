/****************************************************************
example nginx configuration:

http {
  server {
    location /sys/ups {
      proxy_pass http://127.0.0.1:8008/apcupsd;
    }
  }
}
stream {
  upstream apcupsd {
    server 127.0.0.1:3551;
  }

  js_import /etc/nginx/njs.d/apcups.js;

  server {
    listen 127.0.0.1:8008;
    js_filter apcups.filter_apcupsd_request;
    proxy_pass apcupsd;
  }
}
 ****************************************************************/

export default { filter_apcupsd_request };

const cmd_status = Buffer.from([0, 6, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73]);

function filter_apcupsd_request(s) {
  s.on("upstream", function(data, flags) {
    //s.log("recv data " + data.length + " bytes from " + s.rawVariables[remote_addr] + ":" + s.rawVariables[remote_port]);
    s.send(cmd_status, {flush: true});
    s._apcups_resp = [];
    s._apcups_remain = 0;
  });

  s.on("downstream", function(data, flags) {
    //s.log("recv " + data.length + " bytes from apcupsd");
    if (data.length === 0) {
      return;
    }

    let src_off = 0;
    let end = false;
    if (s._apcups_remain) {
      if (s._apcups_remain > data.length) {
        s._apcups_resp[s._apcups_resp.length - 1] += data;
        s._apcups_remain -= data.length;
        return;
      }
      s._apcups_resp[s._apcups_resp.length - 1] += data.subarray(0, s._apcups_remain);
      src_off = s._apcups_remain;
      s._apcups_remain = 0;
    }

    while (src_off < data.length) {
      let c = data.readUIntBE(src_off, 2);
      if (c === 0) {
        end = true;
        break;
      }
      src_off += 2;
      if (src_off + c > data.length) {
        s._apcups_remain = src_off + c - data.length;
        c = data.length - src_off;
      }
      s._apcups_resp.push(data.subarray(src_off, src_off + c));
      src_off += c;
    }

    if (end) {
      let resp = s._apcups_resp.join("");
      s.send("HTTP/1.1 200\r\nConnection: Keep-Alive\r\nKeep-Alive: timeout=60, max=1000\r\nCache-Control: max-age=30\r\nContent-Type: text/plain\r\nContent-Length:" + resp.length + "\r\n\r\n");
      s.send(resp, {flush: true});
    }
  });
}
