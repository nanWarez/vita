-- Use of this source code is governed by the GNU AGPL license; see COPYING.

module(...,package.seeall)

-- This module handles KEY NEGOTIATION with peers and SA CONFIGURATION, which
-- includes dynamically reacting to changes to the routes defined in Vita’s
-- root configuration. For each route defined in the gateway’s configuration a
-- pair of SAs (inbound and outbound) is negotiated and maintained. On change,
-- the set of SAs is written to configuration files picked up by the esp_worker
-- and dsp_worker processes.
--
--                          (neg. proto.)
--                               ||
--                               ||
--               <config> --> KeyManager *--> esp_worker
--                                       |
--                                       \--> dsp_worker

--
-- All things considered, this is the hairy part of Vita, as it covers touchy
-- things such as key generation and expiration, and ultimately presents Vita’s
-- main exploitation surface. On the upside, this module’s data plane doesn’t
-- need worry as much about soft real-time requirements as others, as its
-- generally low-throughput. It can (and should) primarily focus on safety,
-- and can afford more costly dynamic high-level language features to do so.
-- At least to the extent where to doesn’t enable low-traffic DoS, that is.
--
-- In order to insulate failure, this module is composed of three subsystems:
--
--  1. The KeyManager app handles the data plane traffic (key negotiation
--     requests and responses) and configuration plane changes (react to
--     configuration changes and generate configurations for negotiated SAs).
--
--     It tries its best to avoid clobbering valid SA configurations too. I.e.
--     SAs whose routes are not changed in a configuration transition are
--     unaffected by the ensuing re-configuration, allowing for seamless
--     addition of new routes and network address renumbering.
--
--     Whenever SAs are invalidated, i.e. because the route’s pre-shared key or
--     SPI is changed, or because a route is removed entirely, or because the
--     lifetime of a SA pair has expired (sa_ttl), it is destroyed, and
--     eventually re-negotiated if applicable.
--
--     Note that the KeyManager app will attempts to re-negotiate SAs long
--     before they expire (specifically, once half of sa_ttl has passed), in
--     order to avoid loss of tunnel connectivity during re-negotiation.
--
--     Negotiation requests are fed from the input port to the individual
--     Protocol finite-state machine (described below in 2.) of a route, and
--     associated to routes via the Transport wrapper (described below in 3.).
--     Replies and outgoing requests (also obtained by mediating with the
--     Protocol fsm) are sent via the output port.
--
--     Any meaningful events regarding SA negotiation and expiry are logged and
--     registered in the following counters:
--
--        rxerrors                count of all erroneous incoming requests
--                                (includes all others counters)
--
--        route_errors            count of requests that couldn’t be associated
--                                to any configured route
--
--        protocol_errors         count of requests that violated the protocol
--                                (order of messages and message format)
--
--        authentication_errors   count of requests that were detected to be
--                                unauthentic (had an erroneous MAC, this
--                                includes packets corrupted during transit)
--
--        public_key_errors       count of public keys that were rejected
--                                because they were considered unsafe
--
--        negotiations_initiated  count of negotiations initiated by us
--
--        negotiations_expired    count of negotiations expired
--                                (negotiation_ttl)
--
--        nonces_negotiated       count of nonce pairs that were exchanged
--                                (elevated count can indicate DoS attempts)
--
--        keypairs_negotiated     count of ephemeral key pairs that were
--                                exchanged
--
--        keypairs_expired        count of ephemeral key pairs that have
--                                expired (sa_ttl)
--
--  2. The Protocol subsysem implements vita-ske1 (the cryptographic key
--     exchange protocol defined in README.exchange) as a finite-state machine
--     with a timeout (negotiation_ttl) in a way that should be mostly DoS
--     resistant, i.e. it can’t be put into a waiting state by inbound
--     requests.
--
--     For a state transition diagram see: fsm-protocol.svg
--
--     Alternatively it has been considered to implement the protocol on top of
--     a connection based transport protocol (like TCP), i.e. allow multiple
--     concurrent negotiations for each individual route. Such a protocol
--     implementation wasn’t immediately available, and implementing one seemed
--     daunting, and that’s why now each route has just its one own Protocol
--     fsm.
--
--     The Protocol fsm requires its user (the KeyManager app) to “know” about
--     the state transitions of the exchange protocol, but it is written in a
--     way that intends to make fatal misuse impossible, given that one sticks
--     to its public API methods. I.e. it is driven by calling the methods
--
--        initiate_exchange
--        receive_nonce
--        exchange_key
--        receive_key
--        derive_ephemeral_keys
--        reset_if_expired
--
--     which uphold invariants that should ensure any resulting key material is
--     trustworthy, signal any error conditions to the caller, and maintain
--     general consistency of the protocol so that it doesn’t get stuck.
--     Hopefully, the worst consequence of misusing the Protocol fsm is failure
--     to negotiate a key pair.
--
--  3. The Transport header is a super-light transport header that encodes the
--     target SPI and message type of the protocol requests it precedes. It is
--     used by the KeyManager app to parse requests and associate them to the
--     correct route by SPI. It uses the IP protocol type 99 for “any private
--     encryption scheme”.
--
--     It exists explicitly separate from the KeyManager app and Protocol fsm,
--     to clarify that it is interchangable, and logically unrelated to either
--     components.

local S = require("syscall")
local ffi = require("ffi")
local shm = require("core.shm")
local counter = require("core.counter")
local header = require("lib.protocol.header")
local lib = require("core.lib")
local ipv4 = require("lib.protocol.ipv4")
local yang = require("lib.yang.yang")
local schemata = require("program.vita.schemata")
local audit = lib.logger_new({rate=32, module='KeyManager'})
require("program.vita.sodium_h")
local C = ffi.C

PROTOCOL = 99 -- “Any private encryption scheme”

KeyManager = {
   name = "KeyManager",
   config = {
      node_ip4 = {required=true},
      routes = {required=true},
      esp_keyfile = {required=true},
      dsp_keyfile = {required=true},
      negotiation_ttl = {default=10},
      sa_ttl = {default=(24 * 60 * 60)}
   },
   shm = {
      rxerrors = {counter},
      route_errors = {counter},
      protocol_errors = {counter},
      authentication_errors = {counter},
      public_key_errors = {counter},
      negotiations_initiated = {counter},
      negotiations_expired = {counter},
      nonces_negotiated = {counter},
      keypairs_negotiated = {counter},
      keypairs_expired = {counter}
   }
}

local status = { expired = 0, rekey = 1, ready = 2 }

function KeyManager:new (conf)
   local o = {
      routes = {},
      ip = ipv4:new({}),
      transport = Transport.header:new({}),
      nonce_message = Protocol.nonce_message:new({}),
      key_message = Protocol.key_message:new({})
   }
   local self = setmetatable(o, { __index = KeyManager })
   self:reconfig(conf)
   assert(C.sodium_init() >= 0, "Failed to initialize libsodium.")
   return self
end

function KeyManager:reconfig (conf)
   local function find_route (id)
      for _, route in ipairs(self.routes) do
         if route.id == id then return route end
      end
   end
   local function route_match (route, preshared_key, spi)
      return lib.equal(route.preshared_key, preshared_key)
         and route.spi == spi
   end
   local function free_route (route)
      if route.status ~= status.expired then
         audit:log("Expiring keys for '"..route.id.."' (reconfig)")
         self:expire_route(route)
      end
   end

   -- compute new set of routes
   local new_routes = {}
   for id, route in pairs(conf.routes) do
      local new_key = lib.hexundump(route.preshared_key,
                                    Protocol.preshared_key_bytes)
      local old_route = find_route(id)
      if old_route and route_match(old_route, new_key, route.spi) then
         -- keep old route
         table.insert(new_routes, old_route)
         -- if negotation_ttl has changed, swap out old protocol fsm for a new
         -- one with the adjusted timeout, effectively resetting the fsm
         if conf.negotiation_ttl ~= self.negotiation_ttl then
            audit:log("Protocol reset for "..id.." (reconfig)")
            old_route.protocol = Protocol:new(old_route.spi,
                                              old_route.preshared_key,
                                              conf.negotiation_ttl)
         end
      else
         -- insert new new route
         local new_route = {
            id = id,
            gw_ip4n = ipv4:pton(route.gw_ip4),
            preshared_key = new_key,
            spi = route.spi,
            status = status.expired,
            rx_sa = nil, tx_sa = nil,
            sa_timeout = nil, rekey_timeout = nil,
            protocol = Protocol:new(route.spi, new_key, conf.negotiation_ttl)
         }
         table.insert(new_routes, new_route)
         -- clean up after the old route if necessary
         if old_route then free_route(old_route) end
      end
   end

   -- clean up after removed routes
   for _, route in ipairs(self.routes) do
      if not conf.routes[route.id] then free_route(route) end
   end

   -- switch to new configuration
   self.node_ip4n = ipv4:pton(conf.node_ip4)
   self.routes = new_routes
   self.esp_keyfile = shm.root.."/"..shm.resolve(conf.esp_keyfile)
   self.dsp_keyfile = shm.root.."/"..shm.resolve(conf.dsp_keyfile)
   self.negotiation_ttl = conf.negotiation_ttl
   self.sa_ttl = conf.sa_ttl
end

function KeyManager:push ()
   -- handle negotiation protocol requests
   local input = self.input.input
   while not link.empty(input) do
      local request = link.receive(input)
      self:handle_negotiation(request)
      packet.free(request)
   end

   -- process protocol timeouts and initiate (re-)negotiation for SAs
   for _, route in ipairs(self.routes) do
      if route.protocol:reset_if_expired() == Protocol.code.expired then
         counter.add(self.shm.negotiations_expired)
         audit:log("Negotiation expired for '"..route.id.."' (negotiation_ttl")
      end
      if route.status < status.ready then
         self:negotiate(route)
      elseif route.rekey_timeout() then
         route.status = status.rekey
      elseif route.sa_timeout() then
         counter.add(self.shm.keypairs_expired)
         audit:log("Keys expired for '"..route.id.."' (sa_ttl)")
         self:expire_route(route)
      end
   end
end

function KeyManager:negotiate (route)
   local ecode, nonce_message =
      route.protocol:initiate_exchange(self.nonce_message)
   if not ecode then
      counter.add(self.shm.negotiations_initiated)
      audit:log("Initiating negotiation for '"..route.id.."'")
      link.transmit(self.output.output, self:request(route, nonce_message))
   end
end

function KeyManager:handle_negotiation (request)
   local route, message = self:parse_request(request)

   if not (self:handle_nonce_request(route, message)
           or self:handle_key_request(route, message)) then
      counter.add(self.shm.rxerrors)
      audit:log("Rejected invalid negotiation request")
   end
end

function KeyManager:handle_nonce_request (route, message)
   if not route or message ~= self.nonce_message then return end

   local ecode, response = route.protocol:receive_nonce(message)
   if ecode == Protocol.code.protocol then
      counter.add(self.shm.protocol_errors)
      return false
   else assert(not ecode) end

   counter.add(self.shm.nonces_negotiated)
   audit:log("Negotiated nonces for '"..route.id.."'")

   if response then
      link.transmit(self.output.output, self:request(route, response))
   else
      audit:log("Offering keys for '"..route.id.."'")
      local _, key_message = route.protocol:exchange_key(self.key_message)
      link.transmit(self.output.output, self:request(route, key_message))
   end

   return true
end

function KeyManager:handle_key_request (route, message)
   if not route or message ~= self.key_message then return end

   local ecode, response = route.protocol:receive_key(message)
   if ecode == Protocol.code.protocol then
      counter.add(self.shm.protocol_errors)
      return false
   elseif ecode == Protocol.code.authentication then
      counter.add(self.shm.authentication_errors)
      return false
   else assert(not ecode) end

   local ecode, rx, tx = route.protocol:derive_ephemeral_keys()
   if ecode == Protocol.code.parameter then
      counter.add(self.shm.public_key_errors)
      return false
   else assert(not ecode) end

   counter.add(self.shm.keypairs_negotiated)
   audit:log("Completed key exchange for '"..route.id.."'")

   if response then
      link.transmit(self.output.output, self:request(route, response))
   end

   self:configure_route(route, rx, tx)

   return true
end

function KeyManager:configure_route (route, rx, tx)
   route.status = status.ready
   route.rx_sa = {
      mode = "aes-gcm-128-12",
      spi = route.spi,
      key = lib.hexdump(rx.key),
      salt = lib.hexdump(rx.salt)
   }
   route.tx_sa = {
      mode = "aes-gcm-128-12",
      spi = route.spi,
      key = lib.hexdump(tx.key),
      salt = lib.hexdump(tx.salt)
   }
   route.sa_timeout = lib.timeout(self.sa_ttl)
   route.rekey_timeout = lib.timeout(self.sa_ttl/2)
   self:commit_ephemeral_keys()
end

function KeyManager:expire_route (route)
   route.status = status.expired
   route.tx_sa = nil
   route.rx_sa = nil
   route.sa_timeout = nil
   route.rekey_timeout = nil
   self:commit_ephemeral_keys()
end

function KeyManager:request (route, message)
   local request = packet.allocate()

   self.ip:new({
         total_length = ipv4:sizeof()
            + Transport.header:sizeof()
            + message:sizeof(),
         ttl = 64,
         protocol = PROTOCOL,
         src = self.node_ip4n,
         dst = route.gw_ip4n
   })
   packet.append(request, self.ip:header(), ipv4:sizeof())

   self.transport:new({
         spi = route.spi,
         message_type = (message == self.nonce_message
                            and Transport.message_type.nonce)
                     or (message == self.key_message
                            and Transport.message_type.key)
   })
   packet.append(request, self.transport:header(), Transport.header:sizeof())

   packet.append(request, message:header(), message:sizeof())

   return request
end

function KeyManager:parse_request (request)
   local transport = self.transport:new_from_mem(request.data, request.length)
   if not transport then
      counter.add(self.shm.protocol_errors)
      return
   end

   local route = nil
   for _, r in ipairs(self.routes) do
      if transport:spi() == r.spi then
         route = r
         break
      end
   end
   if not route then
      counter.add(self.shm.route_errors)
      return
   end

   local data = request.data + Transport.header:sizeof()
   local length = request.length - Transport.header:sizeof()
   local message = (transport:message_type() == Transport.message_type.nonce
                       and self.nonce_message:new_from_mem(data, length))
                or (transport:message_type() == Transport.message_type.key
                       and self.key_message:new_from_mem(data, length))
   if not message then
      counter.add(self.shm.protocol_errors)
      return
   end

   return route, message
end

local function store_ephemeral_keys (path, keys)
   local f = assert(io.open(path, "w"), "Unable to open file: "..path)
   yang.print_data_for_schema(schemata['ephemeral-keys'], {sa=keys}, f)
   f:close()
end

-- ephemeral_keys := { <id>=(SA), ... }

function KeyManager:commit_ephemeral_keys ()
   local esp_keys, dsp_keys = {}, {}
   for _, route in ipairs(self.routes) do
      if route.status == status.ready then
         esp_keys[route.id] = route.tx_sa
         dsp_keys[route.id] = route.rx_sa
      end
   end
   store_ephemeral_keys(self.esp_keyfile, esp_keys)
   store_ephemeral_keys(self.dsp_keyfile, dsp_keys)
end

-- Vita: simple key exchange (vita-ske, version 1g). See README.exchange

Protocol = {
   status = { idle = 0, wait_nonce = 1, wait_key = 2, complete = 3 },
   code = { protocol = 0, authentication = 1, parameter = 2, expired = 3},
   preshared_key_bytes = C.crypto_auth_hmacsha512256_KEYBYTES,
   public_key_bytes = C.crypto_scalarmult_curve25519_BYTES,
   secret_key_bytes = C.crypto_scalarmult_curve25519_SCALARBYTES,
   auth_code_bytes = C.crypto_auth_hmacsha512256_BYTES,
   nonce_bytes = 32,
   spi_t = ffi.typeof("union { uint32_t u32; uint8_t bytes[4]; }"),
   buffer_t = ffi.typeof("uint8_t[?]"),
   key_t = ffi.typeof[[
      union {
         uint8_t bytes[20];
         struct {
            uint8_t key[16];
            uint8_t salt[4];
         } __attribute__((packed)) slot;
      }
   ]],
   nonce_message = subClass(header),
   key_message = subClass(header)
}
Protocol.nonce_message:init({
      [1] = ffi.typeof([[
            struct {
               uint8_t nonce[]]..Protocol.nonce_bytes..[[];
            } __attribute__((packed))
      ]])
})
Protocol.key_message:init({
      [1] = ffi.typeof([[
            struct {
               uint8_t public_key[]]..Protocol.public_key_bytes..[[];
               uint8_t auth_code[]]..Protocol.auth_code_bytes..[[];
            } __attribute__((packed))
      ]])
})

-- Public API

function Protocol.nonce_message:new (config)
   local o = Protocol.nonce_message:superClass().new(self)
   o:nonce(config.nonce)
   return o
end

function Protocol.nonce_message:nonce (nonce)
   local h = self:header()
   if nonce ~= nil then
      ffi.copy(h.nonce, nonce, ffi.sizeof(h.nonce))
   end
   return h.nonce
end

function Protocol.key_message:new (config)
   local o = Protocol.key_message:superClass().new(self)
   o:public_key(config.public_key)
   o:auth_code(config.auth_code)
   return o
end

function Protocol.key_message:public_key (public_key)
   local h = self:header()
   if public_key ~= nil then
      ffi.copy(h.public_key, public_key, ffi.sizeof(h.public_key))
   end
   return h.public_key
end

function Protocol.key_message:auth_code (auth_code)
   local h = self:header()
   if auth_code ~= nil then
      ffi.copy(h.auth_code, auth_code, ffi.sizeof(h.auth_code))
   end
   return h.auth_code
end

function Protocol:new (spi, key, timeout)
   local o = {
      status = Protocol.status.idle,
      timeout = timeout,
      deadline = nil,
      k = ffi.new(Protocol.buffer_t, Protocol.preshared_key_bytes),
      spi = ffi.new(Protocol.spi_t),
      n1 = ffi.new(Protocol.buffer_t, Protocol.nonce_bytes),
      n2 = ffi.new(Protocol.buffer_t, Protocol.nonce_bytes),
      s1 = ffi.new(Protocol.buffer_t, Protocol.secret_key_bytes),
      p1 = ffi.new(Protocol.buffer_t, Protocol.public_key_bytes),
      p2 = ffi.new(Protocol.buffer_t, Protocol.public_key_bytes),
      h  = ffi.new(Protocol.buffer_t, Protocol.auth_code_bytes),
      q  = ffi.new(Protocol.buffer_t, Protocol.secret_key_bytes),
      e  = ffi.new(Protocol.key_t),
      hmac_state = ffi.new("struct crypto_auth_hmacsha512256_state"),
      hash_state = ffi.new("struct crypto_generichash_blake2b_state")
   }
   ffi.copy(o.k, key, ffi.sizeof(o.k))
   o.spi.u32 = lib.htonl(spi)
   return setmetatable(o, {__index=Protocol})
end

function Protocol:initiate_exchange (nonce_message)
   if self.status == Protocol.status.idle then
      self.status = Protocol.status.wait_nonce
      self:set_deadline()
      return nil, self:send_nonce(nonce_message)
   else return Protocol.code.protocol end
end

function Protocol:receive_nonce (nonce_message)
   if self.status == Protocol.status.idle then
      self:intern_nonce(nonce_message)
      return nil, self:send_nonce(nonce_message)
   elseif self.status == Protocol.status.wait_nonce then
      self:intern_nonce(nonce_message)
      self.status = Protocol.status.wait_key
      self:set_deadline()
      return nil
   else return Protocol.code.protocol end
end

function Protocol:exchange_key (key_message)
   if self.status == Protocol.status.wait_key then
      return nil, self:send_key(key_message)
   else return Protocol.code.protocol end
end

function Protocol:receive_key (key_message)
   if self.status == Protocol.status.idle
   or self.status == Protocol.status.wait_key then
      if self:intern_key(key_message) then
         local response = self.status == Protocol.status.idle
                      and self:send_key(key_message)
         self.status = Protocol.status.complete
         return nil, response
      else return Protocol.code.authentication end
   else return Protocol.code.protocol end
end

function Protocol:derive_ephemeral_keys ()
   if self.status == Protocol.status.complete then
      self:reset()
      if self:derive_shared_secret() then
         local rx = self:derive_key_material(self.p1, self.p2)
         local tx = self:derive_key_material(self.p2, self.p1)
         return nil, rx, tx
      else return Protocol.code.paramter end
   else return Protocol.code.protocol end
end

function Protocol:reset_if_expired ()
   if self.deadline and self.deadline() then
      self:reset()
      return Protocol.code.expired
   end
end

-- Internal methods

function Protocol:send_nonce (nonce_message)
   C.randombytes_buf(self.n1, ffi.sizeof(self.n1))
   return nonce_message:new({nonce=self.n1})
end

function Protocol:intern_nonce (nonce_message)
   ffi.copy(self.n2, nonce_message:nonce(), ffi.sizeof(self.n2))
end

function Protocol:send_key (key_message)
   local spi, k, n1, n2, s1, p1 =
      self.spi, self.k, self.n1, self.n2, self.s1, self.p1
   local state, h1 = self.hmac_state, self.h
   C.randombytes_buf(s1, ffi.sizeof(s1))
   C.crypto_scalarmult_curve25519_base(p1, s1)
   C.crypto_auth_hmacsha512256_init(state, k, ffi.sizeof(k))
   C.crypto_auth_hmacsha512256_update(state, spi.bytes, ffi.sizeof(spi))
   C.crypto_auth_hmacsha512256_update(state, n1, ffi.sizeof(n1))
   C.crypto_auth_hmacsha512256_update(state, n2, ffi.sizeof(n2))
   C.crypto_auth_hmacsha512256_update(state, p1, ffi.sizeof(p1))
   C.crypto_auth_hmacsha512256_final(state, h1)
   return key_message:new({public_key=p1, auth_code=h1})
end

function Protocol:intern_key (m)
   local spi, k, n1, n2, p2 = self.spi, self.k, self.n1, self.n2, self.p2
   local state, h2 = self.hmac_state, self.h
   C.crypto_auth_hmacsha512256_init(state, k, ffi.sizeof(k))
   C.crypto_auth_hmacsha512256_update(state, spi.bytes, ffi.sizeof(spi))
   C.crypto_auth_hmacsha512256_update(state, n2, ffi.sizeof(n2))
   C.crypto_auth_hmacsha512256_update(state, n1, ffi.sizeof(n1))
   C.crypto_auth_hmacsha512256_update(state, m:public_key(), ffi.sizeof(p2))
   C.crypto_auth_hmacsha512256_final(state, h2)
   if C.sodium_memcmp(h2, m:auth_code(), ffi.sizeof(h2)) == 0 then
      ffi.copy(p2, m:public_key(), ffi.sizeof(p2))
      return true
   end
end

function Protocol:derive_shared_secret ()
   return C.crypto_scalarmult_curve25519(self.q, self.s1, self.p2) == 0
end

function Protocol:derive_key_material (salt_a, salt_b)
   local q, e, state = self.q, self.e, self.hash_state
   C.crypto_generichash_blake2b_init(state, nil, 0, ffi.sizeof(e))
   C.crypto_generichash_blake2b_update(state, q, ffi.sizeof(q))
   C.crypto_generichash_blake2b_update(state, salt_a, ffi.sizeof(salt_a))
   C.crypto_generichash_blake2b_update(state, salt_b, ffi.sizeof(salt_b))
   C.crypto_generichash_blake2b_final(state, e.bytes, ffi.sizeof(e.bytes))
   return { key = ffi.string(e.slot.key, ffi.sizeof(e.slot.key)),
            salt = ffi.string(e.slot.salt, ffi.sizeof(e.slot.salt)) }
end

function Protocol:reset ()
   self.deadline = nil
   self.status = Protocol.status.idle
end

function Protocol:set_deadline ()
   self.deadline = lib.timeout(self.timeout)
end

-- Assertions about the world                                              (-:

assert(Protocol.preshared_key_bytes == 32)
assert(Protocol.public_key_bytes == 32)
assert(Protocol.auth_code_bytes == 32)

-- Transport wrapper for vita-ske that encompasses an SPI to map requests to
-- routes, and a message type to facilitate parsing.
--
-- NB: might have to replace this with a UDP based header to get key exchange
-- requests through protocol filters.

Transport = {
   message_type = { nonce = 1, key = 2 },
   header = subClass(header)
}
Transport.header:init({
      [1] = ffi.typeof[[
            struct {
               uint32_t spi;
               uint8_t message_type;
               uint8_t reserved[3];
            } __attribute__((packed))
      ]]
})

-- Public API

function Transport.header:new (config)
   local o = Transport.header:superClass().new(self)
   o:spi(config.spi)
   o:message_type(config.message_type)
   return o
end

function Transport.header:spi (spi)
   local h = self:header()
   if spi ~= nil then
      h.spi = lib.htonl(spi)
   end
   return lib.ntohl(h.spi)
end

function Transport.header:message_type (message_type)
   local h = self:header()
   if message_type ~= nil then
      h.message_type = message_type
   end
   return h.message_type
end
