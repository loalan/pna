/*
Copyright 2022 Advanced Micro Devices, Inc

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

#include <core.p4>
#include "../pna.p4"

/// Crypto accelerator Extern
enum bit<8> crypto_algorithm_e {
    AES_GCM = 1
}
enum bit<8> crypto_results_e {
    SUCCESS = 0,
    AUTH_FAILURE = 1,
    HW_ERROR = 2
}

#define ICV_AFTER_PAYLOAD ((int<32>)-1)
extern crypto_accelerator {
    /// constructor
    /// Some methods provided in this object may be specific to an algorithm used.
    /// Compiler may be able to check and warn/error when incorrect methods are used
    crypto_accelerator(crypto_algorithm_e algo);


    // security association index for this security session
    // Some implementations do not need it.. in that case this method should result in no-op
    void set_sa_index<T>(in T sa_index);

    // Set the initialization data based on protocol used. E.g. salt, random number/ counter for ipsec
    void set_iv<T>(in T iv);
    void set_key<T,S>(in T key, in S key_size);   // 128, 192, 256

    // authentication data format is protocol specific
    // Add this data as a header into the packet and provide its offset and length using the
    // following APIs
    // The format of the auth data is not specified/mandated by this object definition
    void set_auth_data_offset<T>(in T offset);
    void set_auth_data_len<T>(in T len);

    // Alternatively: Following API can be used to consturct protocol specific auth_data and
    // provide it to the engine.
    void add_auth_data<H>(in H auth_data);

    // Auth trailer aka ICV is added by the engine after doing encryption operation
    // Specify icv location - when a wire protocol wants to add ICV in a specific location (e.g. AH)
    // The following apis can be used to specify the location of ICV in the packet
    // special offset (TBD) indicates ICV is after the payload
    void set_icv_offset<T>(in T offset);
    void set_icv_len<L>(in L len);

    // setup payload to be encrypted/decrypted
    void set_payload_offset<T>(in T offset);
    void set_payload_len<T>(in T len);
    
    // operation
    void encrypt<T>(in T enable_auth);
    void decrypt<T>(in T enable_auth);

    // disable engine
    void disable();

    crypto_results_e get_results();       // get results of the previous operation
}

// Helper Externs (could not find it in pna spec/existign code)
extern void recirc_packet() {
    // Vendor specific implementation to cause a packet to get recirculated
}

/// Headers

#define ETHERTYPE_IPV4  0x0800

#define IP_PROTO_TCP    0x06
#define IP_PROTO_UDP    0x11
#define IP_PROTO_ESP    0x50

typedef bit<48>  EthernetAddress;

header ethernet_h {
    EthernetAddress dstAddr;
    EthernetAddress srcAddr;
    bit<16>         etherType;
}

header ipv4_h {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    bit<32> srcAddr;
    bit<32> dstAddr;
}

header tcp_h {
    bit<16>    srcPort;
    bit<16>    dstPort;
    bit<32>    seqNo;
    bit<32>    ackNo;
    bit<4>     dataOffset;
    bit<4>     res;
    bit<8>     flags;
    bit<16>    window;
    bit<16>    checksum;
    bit<16>    urgentPtr;
}

header udp_h {
    bit<16>    srcPort;
    bit<16>    dstPort;
    bit<16>    len;
    bit<16>    checksum;
}

header esp_h {
    bit<32>     spi;
    bit<32>     seq;
}

// rfc4106 esp IV header on the wire
header esp_iv_h {
    bit<64>     iv; // IV on the wire excludes the salt
}
#define IPSEC_OP_NONE       0
#define IPSEC_OP_ENCRYPT    1
#define IPSEC_OP_DECRYPT    2

// Program defined header used during recirculation
header recirc_header_h {
    bit<2>   ipsec_op;
    bit<6>   pad;
    bit<16>  ipsec_len;
}

// User-defined struct containing all of those headers parsed in the
// main parser.
struct headers_t {
    recirc_header_h recirc_header;
    ethernet_h ethernet;
    ipv4_h ipv4_1;
    udp_h udp;
    tcp_h tcp;
    esp_h esp;
    esp_iv_h esp_iv;

    // inner layer - ipsec in tunnel mode
    ipv4_h ipv4_2;
}

/// Metadata

struct main_metadata_t {
    bit<32> sa_index;
    bit<1> ipsec_decrypt_done;
}

/// Instantiate crypto accelerator for AES-GCM algorithm
crypto_accelerator(crypto_algorithm_e.AES_GCM) ipsec_acc;

control PreControlImpl(
    in    headers_t  hdr,
    inout main_metadata_t meta,
    in    pna_pre_input_metadata_t  istd,
    inout pna_pre_output_metadata_t ostd)
{
    apply {
        // Not used in this example
    }
}

parser MainParserImpl(
    packet_in pkt,
    out   headers_t       hdr,
    inout main_metadata_t main_meta,
    in    pna_main_parser_input_metadata_t istd)
{
    bit<1> is_recirc = 0;
    bit<2>  ipsec_op = 0;

    state start {
        main_meta.sa_index = 1; // just for exmaple, used for encrypt

        // TODO: can't find  better indication of recirc in the existing pna.p4
        // This should be a field in istd or and extern
        transition select(istd.loopedback) {
            1 : parse_recirc_header;
            default : parse_packet;
        }
    }

    state parse_recirc_header {
        packet.extract(hdr.recirc_header);
        is_recirc = 1;
        ipsec_op = hdr.recirc_header.ipsec_op;
        transition parse_packet;
    }

    state parse_packet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            ETHERTYPE_IPV4 : parse_ipv4;
            default : accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4_1);
        transition select(hdr.ipv4_1.protocol) {
            IP_PROTO_TCP        : parse_tcp;
            IP_PROTO_UDP        : parse_udp;
            IP_PROTO_ESP        : parse_crypto;
            default             : accept;
        }
    }

    state parse_crypto {
        transition select(is_recirc, ipsec_op) {
            // ESP header is present after decrypt operation
            (0x1 &&& 0x1, IPSEC_OP_DECRYPT &&& 0x3) : parse_post_decrypt;
            // If not recic, this is an encrypted packet, yet to be decrypted
            (0x0 &&& 0x1, 0x0 &&& 0x0) : parse_esp;
            default                    : reject;
        }
    }
    state parse_post_decrypt {
        main_meta.ipsec_decrypt_done = 1;

        packet.extract(hdr.esp);
        packet.extract(hdr.esp_iv);

        // Next header is the decrypted inner ip header parse it again.
        // Pipeline code will have to check the decrypt results and
        // remove any pad, esp trailer and esp auth data
        transition parse_ipv4;
    }
    state parse_esp {
        packet.extract(hdr.esp);
        packet.extract(hdr.esp_iv);
        main_meta.sa_index = hdr.esp.spi;
        transition accept;
    }
    state parse_tcp {
        packet.extract(hdr.tcp);
        transition accept;
    }

    state parse_udp {
        packet.extract(hdr.udp);
        transition accept;
    }
}


control ipsec_crypto( inout headers_t hdr,
                      inout main_metadata_t main_meta,
                      in pna_main_input_metadata_t istd)
{
    action ipsec_esp_decrypt(in bit<32> spi,
                             in bit<32> salt,
                             in bit<256> key,
                             in bit<9> key_size,
                             in bit<1> ext_esn_en,
                             in bit<1> enable_auth,
                             in bit<64> esn) {

        // build IPSec specific IV
        bit<128> iv = (bit<128>)(salt ++ hdr.esp_iv.iv);
        ipsec_acc.set_iv(iv);

        ipsec_acc.set_key(key, key_size);

        // Add protocol specific auth data and provide its offset and len
        bit<16> aad_offset = hdr.ethernet.minSizeInBytes() + 
                             hdr.ipv4_1.minSizeInBytes();

        // For this exmaple 32bit seq num is used
        bit<16> aad_len = hdr.esp.minSizeInBytes();
        hdr.esp.seq = esn[31:0];

        ipsec_acc.set_auth_data_offset(aad_offset);
        ipsec_acc.set_auth_data_len(aad_len);

        // payload_offset : points inner(original) ip header which follows the esp_iv header
        bit<32> encr_pyld_offset = aad_offset + aad_len + hdr.esp_iv.minSizeInBytes();
        ipsec_acc.set_payload_offset(encr_pyld_offset);

        // Encrypted payload_len
        // Remove protocol specific header (E.g. RFC4106)
        bit<16> encr_pyld_len = hdr.ipv4_1.totalLen - hdr.ipv4_1.minSizeInBytes() -
                                hdr.esp.minSizeInBytes() - hdr.esp_iv.minSizeInBytes();


        ipsec_acc.set_payload_offset((bit<16>)encr_pyld_offset);
        ipsec_acc.set_payload_len((bit<16>)encr_pyld_len);

        ipsec_acc.decrypt(enable_auth);

        // recirc
        // add a recirc header to provide decrption info to parser
        hdr.recirc_header.ipsec_op = IPSEC_OP_DECRYPT;
        hdr.recirc_header.ipsec_len = encr_pyld_len;
        hdr.recirc_header.setValid();

        // TODO: recirc_packet() is hardware specific extern
        recirc_packet();
    }

    action ipsec_esp_encrypt(in bit<32> spi,
                             in bit<32> salt,
                             in bit<256> key,
                             in bit<9> key_size,
                             in bit<1> ext_esn_en,
                             in bit<1> enable_auth,
                             in bit<64> esn) {

        // Initialize the ipsec accelerator
        // esn = esn + 1;

        // Set IV information needed for encryption
        // For ipsec combine salt and esn
        bit<128> iv = (bit<128>)(salt ++ esn);
        ipsec_acc.set_iv(iv);

        ipsec_acc.set_key(key, key_size);

        // For tunnel mode, operation, copy original IP header that needs to
        // be encrypted. This header will be emitted after ESP header.
        hdr.ipv4_2 = hdr.ipv4_1;
        hdr.ipv4_2.setValid();

        // Add protocol specific headers to the packet (rfc4106)
        // 32bit seq number is used
        hdr.esp.spi = spi;
        hdr.esp.seq = esn[31:0];
        hdr.esp.setValid();

        hdr.esp_iv = esn;
        hdr.esp_iv.setValid();

        // update tunnel ip header
        hdr.ipv4_1.totalLen = hdr.ipv4_2.totalLen + hdr.esp.minSizeInBytes() +
                              hdr.esp_iv.minSizeInBytes();
        // Set outer header's next header as ESP
        hdr.ipv4_1.protocol = IP_PROTO_ESP;

        bit<16> aad_offset = hdr.ethernet.minSizeInBytes() + 
                             hdr.ipv4_1.minSizeInBytes();
        bit<16> aad_len = hdr.esp.minSizeInBytes();

        ipsec_acc.set_auth_data_offset(aad_offset);
        ipsec_acc.set_auth_data_len(aad_len);

        // payload_offset : points inner(original) ip header which follows the esp header
        bit<32> encr_pyld_offset = aad_offset + aad_len;
        ipsec_acc.set_payload_offset(encr_pyld_offset);

        // payload_len : data to be encrypted
        // Remove protocol specific header (E.g. RFC4106)
        bit<16> encr_pyld_len = hdr.ipv4_2.totalLen;

        ipsec_acc.set_payload_len(encr_pyld_len);

        // TODO: compute padding, build esp_trailer etc.

        // instruct engine to add icv after encrypted payload
        ipsec_acc.set_icv_offset(ICV_AFTER_PAYLOAD);
        ipsec_acc.set_icv_len(4); // Four bytes of ICV value.


        // run encryption w/ authentication
        ipsec_acc.encrypt(enable_auth);
    }

    @name (".ipsec_sa_action")
    action ipsec_sa_lookup_action(in bit<32>    spi,
                                  in bit<32>    salt,
                                  in bit<256>   key,
                                  in bit<9>     key_size,
                                  in bit<1>     ext_esn_en,
                                  in bit<1>     auth_en,
                                  in bit<1>     valid_flag,
                                  in bit<64>    esn) {
        if (valid_flag == 0) {
            return;
        }
        if (!hdr.esp.isValid()) {
            ipsec_esp_encrypt(spi, salt, key, key_size, ext_esn_en, auth_en, esn);
        } else {
            ipsec_esp_decrypt(spi, salt, key, key_size, ext_esn_en, auth_en, esn);
        }
    }
    // setup crypto accelerator for decryption - get info from sa table
    // lookup sa_table using esp.spi
    table ipsec_sa {
        key = {
            // For encrypt case get sa_idx from parser
            // for decrypt case esp hdr spi value will be used as sa_idx
            main_meta.sa_index  : exact;
        } 
        actions  = {
            ipsec_sa_action;
        }
        default_action = ipsec_sa_action;
    }
}

control ipsec_post_decrypt(
    inout headers_t       hdr,
    inout main_metadata_t main_meta,
    in    pna_main_input_metadata_t  istd)
{
    // post decrypt processing happens here
    // E.g. remove any unrequired headers such as outer headers in tunnel mode etc..
    if (ipsec_acc.get_results() != crypto_results_e.SUCCESS) {
        // TODO:
        // Check if this is AUTH error or some other error.
        // Drop the packet or do other things as needed
        drop_packet();
        return;
    }
    // remove outer (tunnel headers), make inner header
    hdr.ipv4_1 = hdr.ipv4_2;
    hdr.ipv4_2.setInvalid();

    // Remove ipsec related headers from the packet
    hdr.ipsec_esp.setInvalid();
    hdr.ipsec_esp_iv.setInvalid();

    // Process rest of packet as required
    // ...
    return;
}

control MainControlImpl(
    inout headers_t       hdr,
    inout main_metadata_t main_meta,
    in    pna_main_input_metadata_t  istd,
    inout pna_main_output_metadata_t ostd)
{
    apply {
        if (main_meta.ipsec_decrypt_done == 1) {
            ipsec_post_decrypt.apply(hdr, main_meta, istd);
        } else {
            ipsec_crypto.apply(hdr, main_meta, istd);
        }
    }
}

control MainDeparserImpl(
    packet_out pkt,
    in    headers_t hdr,                // from main control
    in    main_metadata_t user_meta,    // from main control
    in    pna_main_output_metadata_t ostd)
{
    apply {
        pkt.emit(hdr.recirc_header);
        pkt.emit(hdr.ethernet);
        pkt.emit(hdr.ipv4_1);
        pkt.emit(hdr.esp);
        pkt.emit(hdr.esp_iv);
        pkt.emit(hdr.ipv4_2);
        pkt.emit(hdr.tcp);
        pkt.emit(hdr.udp);
    }
}

// Package_Instantiation
PNA_NIC(
    MainParserImpl(),
    PreControlImpl(),
    MainControlImpl(),
    MainDeparserImpl()
    ) main;
