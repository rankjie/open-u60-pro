//! TURN packet transport over TCP (RFC 8656 sections 12.4–12.6).
use async_trait::async_trait;
use std::{any::Any, io, net::SocketAddr, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{
        tcp::{OwnedReadHalf, OwnedWriteHalf},
        TcpStream,
    },
    sync::{watch, Mutex},
};
use util::{conn::Conn, Result};

struct Reader {
    stream: OwnedReadHalf,
    pending: Vec<u8>,
}
pub(super) struct TurnTcp {
    local: SocketAddr,
    remote: SocketAddr,
    reader: Mutex<Reader>,
    writer: Mutex<OwnedWriteHalf>,
    closed: watch::Sender<bool>,
}
fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid TURN TCP frame")
}
fn closed() -> io::Error {
    io::Error::new(io::ErrorKind::NotConnected, "TURN TCP connection closed")
}

// Return application length and wire length. ChannelData padding belongs to the
// stream, not its length field; STUN's length excludes its 20-byte header.
fn lengths(bytes: &[u8]) -> io::Result<Option<(usize, usize)>> {
    if bytes.len() < 4 {
        return Ok(None);
    }
    let size = usize::from(u16::from_be_bytes([bytes[2], bytes[3]]));
    if bytes[0] & 0xc0 == 0 {
        if size % 4 != 0 {
            return Err(invalid());
        }
        if bytes.len() < 8 {
            return Ok(None);
        }
        if bytes[4..8] != [0x21, 0x12, 0xa4, 0x42] {
            return Err(invalid());
        }
        Ok(Some((20 + size, 20 + size)))
    } else if bytes[0] & 0xc0 == 0x40 {
        Ok(Some((4 + size, (4 + size + 3) & !3)))
    } else {
        Err(invalid())
    }
}
impl TurnTcp {
    pub(super) async fn dial(remote: SocketAddr) -> io::Result<Self> {
        let stream = tokio::time::timeout(Duration::from_secs(5), TcpStream::connect(remote))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "TURN TCP connect timeout"))??;
        stream.set_nodelay(true)?;
        let local = stream.local_addr()?;
        let (reader, writer) = stream.into_split();
        let (closed, _) = watch::channel(false);
        Ok(Self {
            local,
            remote,
            reader: Mutex::new(Reader {
                stream: reader,
                pending: Vec::new(),
            }),
            writer: Mutex::new(writer),
            closed,
        })
    }
    async fn receive(&self, output: &mut [u8]) -> io::Result<usize> {
        let mut stopped = self.closed.subscribe();
        if *stopped.borrow() {
            return Err(closed());
        }
        let mut reader = tokio::select! { _=stopped.changed()=>return Err(closed()), lock=self.reader.lock()=>lock };
        loop {
            if *stopped.borrow() {
                return Err(closed());
            }
            match lengths(&reader.pending) {
                Err(error) => {
                    self.closed.send_replace(true);
                    return Err(error);
                }
                Ok(Some((size, wire))) => {
                    if size > output.len() {
                        self.closed.send_replace(true);
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "TURN TCP packet exceeds receive buffer",
                        ));
                    }
                    if reader.pending.len() >= wire {
                        output[..size].copy_from_slice(&reader.pending[..size]);
                        reader.pending.drain(..wire);
                        return Ok(size);
                    }
                }
                Ok(None) => {}
            }
            let mut chunk = [0; 2048];
            let count = tokio::select! { _=stopped.changed()=>return Err(closed()), count=reader.stream.read(&mut chunk)=>count? };
            if count == 0 {
                self.closed.send_replace(true);
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "TURN TCP peer closed",
                ));
            }
            // Buffered bytes survive cancellation of a receive future midway
            // through a fragmented frame; resuming cannot lose stream alignment.
            reader.pending.extend_from_slice(&chunk[..count]);
        }
    }
    async fn transmit(&self, bytes: &[u8]) -> io::Result<usize> {
        let Some((size, wire)) = lengths(bytes)? else {
            return Err(invalid());
        };
        if bytes.len() != size && bytes.len() != wire {
            return Err(invalid());
        }
        let mut stopped = self.closed.subscribe();
        if *stopped.borrow() {
            return Err(closed());
        }
        let mut writer = tokio::select! { _=stopped.changed()=>return Err(closed()), lock=self.writer.lock()=>lock };
        struct Incomplete<'a> {
            closed: &'a watch::Sender<bool>,
            complete: bool,
        }
        impl Drop for Incomplete<'_> {
            fn drop(&mut self) {
                if !self.complete {
                    self.closed.send_replace(true);
                }
            }
        }
        let mut transaction = Incomplete {
            closed: &self.closed,
            complete: false,
        };
        let result = tokio::time::timeout(Duration::from_secs(5), async {
            writer.write_all(bytes).await?;
            if bytes.len() < wire {
                writer.write_all(&[0; 3][..wire - bytes.len()]).await?;
            }
            Ok::<(), io::Error>(())
        });
        tokio::select! { _=stopped.changed()=>return Err(closed()), result=result=>result.map_err(|_|io::Error::new(io::ErrorKind::TimedOut,"TURN TCP write timeout"))?? };
        transaction.complete = true;
        Ok(bytes.len())
    }
}
#[async_trait]
impl Conn for TurnTcp {
    async fn connect(&self, target: SocketAddr) -> Result<()> {
        if target != self.remote {
            return Err(invalid().into());
        }
        Ok(())
    }
    async fn recv(&self, bytes: &mut [u8]) -> Result<usize> {
        Ok(self.receive(bytes).await?)
    }
    async fn recv_from(&self, bytes: &mut [u8]) -> Result<(usize, SocketAddr)> {
        Ok((self.receive(bytes).await?, self.remote))
    }
    async fn send(&self, bytes: &[u8]) -> Result<usize> {
        Ok(self.transmit(bytes).await?)
    }
    async fn send_to(&self, bytes: &[u8], target: SocketAddr) -> Result<usize> {
        if target != self.remote {
            return Err(invalid().into());
        }
        self.send(bytes).await
    }
    fn local_addr(&self) -> Result<SocketAddr> {
        Ok(self.local)
    }
    fn remote_addr(&self) -> Option<SocketAddr> {
        Some(self.remote)
    }
    async fn close(&self) -> Result<()> {
        self.closed.send_replace(true);
        tokio::time::timeout(Duration::from_secs(6), async {
            self.writer.lock().await.shutdown().await
        })
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "TURN TCP shutdown timeout"))??;
        Ok(())
    }
    fn as_any(&self) -> &(dyn Any + Send + Sync) {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;
    async fn pair() -> (TurnTcp, TcpStream) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let (client, server) = tokio::join!(
            TurnTcp::dial(listener.local_addr().unwrap()),
            listener.accept()
        );
        (client.unwrap(), server.unwrap().0)
    }
    fn stun() -> Vec<u8> {
        let mut message = vec![0; 20];
        message[0] = 1;
        message[4..8].copy_from_slice(&[0x21, 0x12, 0xa4, 0x42]);
        message
    }
    #[tokio::test]
    async fn fragmented_and_coalesced_frames_preserve_boundaries_after_cancellation() {
        let (client, mut server) = pair().await;
        let packet = stun();
        let mut output = [0; 100];
        server.write_all(&packet[..5]).await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(20), client.recv(&mut output))
                .await
                .is_err()
        );
        let mut rest = packet[5..].to_vec();
        rest.extend_from_slice(&[0x40, 1, 0, 1, 42, 0, 0, 0]);
        rest.extend_from_slice(&packet);
        server.write_all(&rest).await.unwrap();
        assert_eq!(client.recv(&mut output).await.unwrap(), 20);
        assert_eq!(&output[..20], packet);
        assert_eq!(client.recv(&mut output).await.unwrap(), 5);
        assert_eq!(&output[..5], &[0x40, 1, 0, 1, 42]);
        assert_eq!(client.recv(&mut output).await.unwrap(), 20);
        assert_eq!(&output[..20], packet);
    }
    #[tokio::test]
    async fn outgoing_channel_data_is_padded_and_close_unblocks_a_receiver() {
        let (client, mut server) = pair().await;
        assert_eq!(client.send(&[0x40, 1, 0, 1, 42]).await.unwrap(), 5);
        let mut bytes = [0; 8];
        server.read_exact(&mut bytes).await.unwrap();
        assert_eq!(bytes, [0x40, 1, 0, 1, 42, 0, 0, 0]);
        let receive = async {
            let mut buffer = [0; 100];
            client.recv(&mut buffer).await
        };
        let close = async {
            tokio::time::sleep(Duration::from_millis(20)).await;
            client.close().await.unwrap();
        };
        let (result, _) = tokio::time::timeout(Duration::from_secs(1), async {
            tokio::join!(receive, close)
        })
        .await
        .unwrap();
        assert!(result.is_err());
        assert!(client.send(&stun()).await.is_err());
    }
    #[tokio::test]
    async fn malformed_or_oversized_messages_fail_the_connection() {
        for packet in [vec![0x80, 0, 0, 0], vec![0x40, 1, 1, 0], vec![0, 1, 0, 1]] {
            let (client, mut server) = pair().await;
            server.write_all(&packet).await.unwrap();
            let mut output = [0; 20];
            assert!(
                tokio::time::timeout(Duration::from_secs(1), client.recv(&mut output))
                    .await
                    .unwrap()
                    .is_err()
            );
            assert!(client.send(&stun()).await.is_err());
        }
    }
}
