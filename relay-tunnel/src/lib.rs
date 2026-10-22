//! A QUIC port forward for the relay's HTTP/WebSocket service.
//!
//! Each bidirectional QUIC stream carries one TCP connection byte for byte, so the service
//! protocol above it is unchanged. The gateway forwards every stream to one fixed upstream; it
//! is not a proxy. Clients authenticate the gateway by the SHA-256 of its certificate, which
//! travels with the relay address, so no domain or public certificate is involved.

use std::fmt;
use std::io;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use base64::Engine;
use quinn::crypto::rustls::{QuicClientConfig, QuicServerConfig};
use quinn::{Connection, Endpoint, RecvStream, SendStream, TransportConfig};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime};
use rustls::{CertificateError, DigitallySignedStruct, SignatureScheme};
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;
use tokio::task::JoinHandle;

pub const ALPN: &[u8] = b"openu60-tunnel/1";
/// The name in the self-signed certificate. Identity comes from the pin, not this name.
const SERVER_NAME: &str = "openu60-relay";
/// Below typical carrier NAT UDP timeouts (about 30 s), so the router stays reachable.
const KEEP_ALIVE: Duration = Duration::from_secs(15);
const IDLE_TIMEOUT: Duration = Duration::from_secs(60);
const MAX_STREAMS: u32 = 128;

/// SHA-256 of the gateway's DER certificate.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Pin(pub [u8; 32]);

impl Pin {
    pub fn of(certificate: &[u8]) -> Self {
        Pin(Sha256::digest(certificate).into())
    }

    /// Unpadded base64url, as carried in relay addresses.
    pub fn parse(text: &str) -> Result<Self, &'static str> {
        let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(text)
            .map_err(|_| "invalid_relay_pin")?;
        Ok(Pin(bytes.try_into().map_err(|_| "invalid_relay_pin")?))
    }
}

impl fmt::Display for Pin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(self.0))
    }
}

impl fmt::Debug for Pin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Pin({self})")
    }
}

fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

fn transport(keep_alive: bool) -> Arc<TransportConfig> {
    let mut transport = TransportConfig::default();
    transport.max_idle_timeout(Some(IDLE_TIMEOUT.try_into().expect("idle timeout fits")));
    transport.max_concurrent_bidi_streams(MAX_STREAMS.into());
    transport.max_concurrent_uni_streams(0u32.into());
    if keep_alive {
        transport.keep_alive_interval(Some(KEEP_ALIVE));
    }
    Arc::new(transport)
}

// MARK: - Gateway

/// The gateway's certificate and key, created once and kept so the pin stays stable.
pub struct Identity {
    certificate: CertificateDer<'static>,
    key: PrivatePkcs8KeyDer<'static>,
}

impl Identity {
    pub fn load_or_create(directory: &Path) -> io::Result<Self> {
        let certificate_file = directory.join("certificate.der");
        let key_file = directory.join("key.der");
        if certificate_file.exists() || key_file.exists() {
            return Ok(Identity {
                certificate: CertificateDer::from(std::fs::read(&certificate_file)?),
                key: PrivatePkcs8KeyDer::from(std::fs::read(&key_file)?),
            });
        }
        let generated = rcgen::generate_simple_self_signed(vec![SERVER_NAME.to_string()])
            .map_err(|error| io::Error::other(error.to_string()))?;
        let identity = Identity {
            certificate: generated.cert.der().clone(),
            key: PrivatePkcs8KeyDer::from(generated.key_pair.serialize_der()),
        };
        std::fs::create_dir_all(directory)?;
        write_private(&key_file, identity.key.secret_pkcs8_der())?;
        write_private(&certificate_file, identity.certificate.as_ref())?;
        Ok(identity)
    }

    pub fn pin(&self) -> Pin {
        Pin::of(self.certificate.as_ref())
    }
}

fn write_private(file: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write;
    #[cfg(unix)]
    use std::os::unix::fs::OpenOptionsExt;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    options.open(file)?.write_all(bytes)
}

pub fn gateway(identity: &Identity, listen: SocketAddr) -> io::Result<Endpoint> {
    let mut crypto = rustls::ServerConfig::builder_with_provider(provider())
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(io::Error::other)?
        .with_no_client_auth()
        .with_single_cert(
            vec![identity.certificate.clone()],
            PrivateKeyDer::Pkcs8(identity.key.clone_key()),
        )
        .map_err(io::Error::other)?;
    crypto.alpn_protocols = vec![ALPN.to_vec()];
    let crypto = QuicServerConfig::try_from(crypto).map_err(io::Error::other)?;
    let mut config = quinn::ServerConfig::with_crypto(Arc::new(crypto));
    config.transport_config(transport(false));
    Endpoint::server(config, listen)
}

/// Forwards every stream of every connection to `upstream` until the endpoint closes.
pub async fn serve(endpoint: Endpoint, upstream: SocketAddr) {
    while let Some(incoming) = endpoint.accept().await {
        tokio::spawn(async move {
            let Ok(connection) = incoming.await else { return };
            while let Ok((send, recv)) = connection.accept_bi().await {
                tokio::spawn(async move {
                    let Ok(tcp) = TcpStream::connect(upstream).await else { return };
                    pipe(tcp, send, recv).await;
                });
            }
        });
    }
}

// MARK: - Addresses

/// A door address: `quic://host:port#pin`. The fragment carries the certificate pin.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Door {
    pub host: String,
    pub port: u16,
    pub pin: Pin,
}

impl Door {
    pub fn parse(text: &str) -> Result<Self, &'static str> {
        let rest = text.strip_prefix("quic://").ok_or("invalid_door")?;
        let (authority, pin) = rest.split_once('#').ok_or("invalid_door")?;
        let authority = authority.trim_end_matches('/');
        let (host, port) = if let Some(bracketed) = authority.strip_prefix('[') {
            let (host, port) = bracketed.split_once("]:").ok_or("invalid_door")?;
            (host, port)
        } else {
            authority.rsplit_once(':').ok_or("invalid_door")?
        };
        if host.is_empty() || host.contains(['/', '@', '?', ' ']) {
            return Err("invalid_door");
        }
        Ok(Door {
            host: host.to_string(),
            port: port.parse().map_err(|_| "invalid_door")?,
            pin: Pin::parse(pin)?,
        })
    }

    /// Resolves the host now; doors may be named, and names may move between addresses.
    pub async fn resolve(&self) -> io::Result<SocketAddr> {
        tokio::net::lookup_host((self.host.as_str(), self.port))
            .await?
            .next()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "door has no address"))
    }
}

impl fmt::Display for Door {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.host.contains(':') {
            write!(f, "quic://[{}]:{}#{}", self.host, self.port, self.pin)
        } else {
            write!(f, "quic://{}:{}#{}", self.host, self.port, self.pin)
        }
    }
}

// MARK: - Client

#[derive(Debug)]
struct PinnedVerifier {
    pin: Pin,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for PinnedVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        if Pin::of(end_entity.as_ref()) == self.pin {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::InvalidCertificate(CertificateError::ApplicationVerificationFailure))
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            certificate,
            signature,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            certificate,
            signature,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

/// A loopback TCP port that reaches the gateway's upstream through one shared QUIC connection.
pub struct Tunnel {
    local: SocketAddr,
    state: Arc<ClientState>,
    task: JoinHandle<()>,
}

struct ClientState {
    endpoint: Endpoint,
    server: SocketAddr,
    connection: Mutex<Option<Connection>>,
}

impl ClientState {
    async fn connection(&self) -> io::Result<Connection> {
        let mut current = self.connection.lock().await;
        if let Some(connection) = current.as_ref().filter(|c| c.close_reason().is_none()) {
            return Ok(connection.clone());
        }
        let connecting = self
            .endpoint
            .connect(self.server, SERVER_NAME)
            .map_err(io::Error::other)?;
        let connection = connecting.await.map_err(io::Error::other)?;
        *current = Some(connection.clone());
        Ok(connection)
    }

    async fn open(&self) -> io::Result<(SendStream, RecvStream)> {
        let connection = self.connection().await?;
        match connection.open_bi().await {
            Ok(streams) => Ok(streams),
            // A connection that died since it was last used is replaced once.
            Err(_) => {
                self.connection.lock().await.take();
                self.connection().await?.open_bi().await.map_err(io::Error::other)
            }
        }
    }
}

impl Tunnel {
    pub async fn start(server: SocketAddr, pin: Pin) -> io::Result<Tunnel> {
        let provider = provider();
        let mut crypto = rustls::ClientConfig::builder_with_provider(provider.clone())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .map_err(io::Error::other)?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(PinnedVerifier { pin, provider }))
            .with_no_client_auth();
        crypto.alpn_protocols = vec![ALPN.to_vec()];
        let crypto = QuicClientConfig::try_from(crypto).map_err(io::Error::other)?;
        let mut config = quinn::ClientConfig::new(Arc::new(crypto));
        config.transport_config(transport(true));
        let bind: SocketAddr = if server.is_ipv4() {
            (Ipv4Addr::UNSPECIFIED, 0).into()
        } else {
            (Ipv6Addr::UNSPECIFIED, 0).into()
        };
        let mut endpoint = Endpoint::client(bind)?;
        endpoint.set_default_client_config(config);
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
        let local = listener.local_addr()?;
        let state = Arc::new(ClientState { endpoint, server, connection: Mutex::new(None) });
        let accepting = state.clone();
        let task = tokio::spawn(async move {
            while let Ok((tcp, _)) = listener.accept().await {
                let state = accepting.clone();
                tokio::spawn(async move {
                    // A failed open drops the TCP connection; the caller sees a closed socket.
                    if let Ok((send, recv)) = state.open().await {
                        pipe(tcp, send, recv).await;
                    }
                });
            }
        });
        Ok(Tunnel { local, state, task })
    }

    /// Resolves a door and starts a tunnel to it.
    pub async fn connect(door: Door) -> io::Result<Tunnel> {
        Tunnel::start(door.resolve().await?, door.pin).await
    }

    /// The loopback address that HTTP and WebSocket clients connect to.
    pub fn local_addr(&self) -> SocketAddr {
        self.local
    }

    /// Establishes the QUIC connection now and returns its round-trip time.
    pub async fn probe(&self) -> io::Result<Duration> {
        Ok(self.state.connection().await?.rtt())
    }
}

impl Drop for Tunnel {
    fn drop(&mut self) {
        self.task.abort();
        self.state.endpoint.close(0u32.into(), b"closed");
    }
}

// MARK: - Piping

/// Copies both directions, preserving half-close: an HTTP client that finishes its request
/// still receives the response.
async fn pipe(tcp: TcpStream, mut send: SendStream, mut recv: RecvStream) {
    let _ = tcp.set_nodelay(true);
    let (mut tcp_read, mut tcp_write) = tcp.into_split();
    let outbound = async {
        let _ = tokio::io::copy(&mut tcp_read, &mut send).await;
        let _ = send.finish();
    };
    let inbound = async {
        let _ = tokio::io::copy(&mut recv, &mut tcp_write).await;
        let _ = tcp_write.shutdown().await;
    };
    tokio::join!(outbound, inbound);
}
