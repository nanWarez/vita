-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local ethernet = require("lib.protocol.ethernet")
local arp = require("lib.protocol.arp")
local arp_ipv4 = require("lib.protocol.arp_ipv4")
local ipv4 = require("lib.protocol.ipv4")
local datagram = require("lib.protocol.datagram")
local ctable = require("lib.ctable")
local ffi = require("ffi")

-- NextHop4 forwards IPv4 packets to the next hop and resolves Ethernet
-- addresses via ARP, see https://tools.ietf.org/html/rfc826

NextHop4 = {
   name = "NextHop4",
   config = {
      node_mac = {required=true},
      node_ip4 = {required=true},
      nexthop_ip4 = {}
   }
}

function NextHop4:new (conf)
   local o = {}
   o.node_mac = ethernet:pton(conf.node_mac)
   o.node_ip4 = ipv4:pton(conf.node_ip4)
   o.nexthop_ip4 = ipv4:pton(conf.nexthop_ip4)

   -- Ethernet frame header (node → nexthop)
   o.eth =  ethernet:new{
      type = 0x0800, -- IPv4
      src = o.node_mac
   }

   -- ARP request template
   o.request = {
      p = packet.allocate(),
      arp_ipv4 = arp_ipv4:new{sha=o.node_mac, spa=o.node_ip4}
   }
   local d = datagram:new(o.request.p)
   d:push(o.request.arp_ipv4)
   d:push(arp:new{
             op = 'request',
             pro = arp_ipv4.PROTOCOL,
             pln = arp_ipv4.ADDRESS_BYTES
   })
   d:push(ethernet:new{
             type = arp.ETHERTYPE,
             src = o.node_mac,
             dst = ethernet:pton("FF:FF:FF:FF:FF:FF")
   })
   o.request.p = d:packet()
   o.request.arp_ipv4:new_from_mem(
      o.request.p.data + ethernet:sizeof() + arp:sizeof(),
      o.request.p.length - ethernet:sizeof() - arp:sizeof()
   )

   -- Headers to parse
   o.arp = arp:new{}
   o.arp_ipv4 = arp_ipv4:new{}
   o.ip4 = ipv4:new{}

   -- ARP translation table
   o.arp_table = ctable.new{
      key_type = ffi.typeof("uint8_t[4]"), -- IPv4
      value_type = ffi.typeof("uint8_t[6]") -- MAC address
   }

   return setmetatable(o, {__index = NextHop4})
end

function NextHop4:stop ()
   packet.free(self.request.p)
end

function NextHop4:link ()
   -- We receive `arp' messages on the `arp' port, and traffic to be forwarded
   -- on all other input ports.
   self.forward = {}
   for _, link in ipairs(self.input) do
      if link ~= self.input.arp then
         table.insert(self.forward, link)
      end
   end
end

function NextHop4:push ()
   local output = self.output.output

   -- Forward packets to next hop and perform ARP requests
   for _, input in ipairs(self.forward) do
      for _=1,link.nreadable(input) do
         local p = link.receive(input)
         local nexthop_ip4 = self.nexthop_ip4
         if not nexthop_ip4 then
            -- Default to destination host unless a static nexthop is
            -- configured
            assert(self.ip4:new_from_mem(p.data, p.length), "packet too short")
            nexthop_ip4 = self.ip4:dst()
         end
         local entry = self.arp_table:lookup_ptr(nexthop_ip4)
         if entry then
            link.transmit(output, self:encapsulate(p, entry.value))
         else
            packet.free(p)
            link.transmit(output, self:arp_request(nexthop_ip4))
         end
      end
   end

   -- Handle incoming ARP requests and replies
   local arp_input = self.input.arp
   for _=1,link.nreadable(arp_input) do
      local p = link.receive(arp_input)
      local reply = self:handle_arp(p)
      if reply then
         link.transmit(output, reply)
      else
         packet.free(p)
      end
   end
end

function NextHop4:encapsulate (p, dst)
   self.eth:dst(dst)
   return packet.prepend(p, self.eth:header_ptr(), ethernet:sizeof())
end

function NextHop4:arp_request (ip)
   self.request.arp_ipv4:tpa(ip)
   return packet.clone(self.request.p)
end

local function ip4eq (x, y)
   return ffi.cast("uint32_t *", x)[0] == ffi.cast("uint32_t *", y)[0]
end

function NextHop4:handle_arp (p)
   local arp_hdr, arp_ipv4 = self.arp, self.arp_ipv4
   -- ?Do I have the hardware type in ar$hrd?
   -- Yes: (almost definitely)
   --    [optionally check the hardware length ar$hln]
   --    ?Do I speak the protocol in ar$pro?
   if arp_hdr:new_from_mem(p.data, p.length)
      and arp_hdr:hrd() == arp.ETHERNET
      and arp_hdr:pro() == arp_ipv4.PROTOCOL
      and arp_ipv4:new_from_mem(p.data + arp:sizeof(), p.length - arp:sizeof())
   then
      -- Yes:
      --    [optionally check the protocol length ar$pln]
      --    Merge_flag := false
      local entry = self.arp_table:lookup_ptr(arp_ipv4:spa())
      --    If the pair <protocol type, sender protocol address> is
      --        already in my translation table, update the sender
      --        hardware address field of the entry with the new
      --        information in the packet and set Merge_flag to true.
      if entry then
         entry.value = arp_ipv4:sha()
      end
      --    ?Am I the target protocol address?
      if ip4eq(arp_ipv4:tpa(), self.node_ip4) then
         -- Yes:
         --    If Merge_flag is false, add the triplet <protocol type,
         --        sender protocol address, sender hardware address> to
         --        the translation table.
         if not entry then
            self.arp_table:add(arp_ipv4:spa(), arp_ipv4:sha())
         end
         --    ?Is the opcode ares_op$REQUEST?  (NOW look at the opcode!!)
         if arp_hdr:op() == 'request' then
            -- Yes:
            --    Swap hardware and protocol fields, putting the local
            --        hardware and protocol addresses in the sender fields.
            arp_ipv4:tha(arp_ipv4:sha())
            arp_ipv4:sha(self.node_mac)
            arp_ipv4:tpa(arp_ipv4:spa())
            arp_ipv4:spa(self.node_ip4)
            --    Set the ar$op field to ares_op$REPLY
            arp_hdr:op('reply')
            --    Send the packet to the (new) target hardware address on
            --        the same hardware on which the request was received.
            return self:encapsulate(p, arp_ipv4:tha())
         end
      end
   end
end
