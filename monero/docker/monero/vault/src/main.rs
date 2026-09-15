use hmac::{Hmac, Mac};
use openssl::rand::rand_bytes;
use openssl::symm::{Cipher, Crypter, Mode};
use sha2::Sha256;
use std::env;
use std::error::Error;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::FromRawFd;
use std::os::raw::{c_char, c_int};
use std::path::{Component, Path, PathBuf};
use subtle::ConstantTimeEq;
use tar::{Archive, Builder};
use tempfile::tempfile;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

type HmacSha256 = Hmac<Sha256>;
type VaultResult<T> = Result<T, Box<dyn Error>>;

const SECTOR_SIZE: usize = 4096;
const TAG_SIZE: usize = 32;
const INNER_HEADER_SIZE: usize = 64;
const XTS_KEY_SIZE: usize = 64;
const MAC_KEY_SIZE: usize = 32;
const KEY_MATERIAL_SIZE: usize = XTS_KEY_SIZE + MAC_KEY_SIZE;
const PASSWORD_MAX: usize = 512;
const MAX_DATA_SIZE: u64 = 16 * 1024 * 1024 * 1024;
const ARGON2ID_OPSLIMIT: u64 = 3;
const ARGON2ID_MEMLIMIT: usize = 64 * 1024 * 1024;
const ARGON2ID_ALGORITHM: c_int = 2;
const KDF_SALT: [u8; 16] = *b"mgla-raw-v1-kdf!";
const HMAC_CONTEXT: &[u8] = b"MGLA-RAW-V1-HMAC";
const INNER_MAGIC: &[u8] = b"MGLA-RAW-V1";

#[link(name = "sodium")]
unsafe extern "C" {
    fn sodium_init() -> c_int;
    fn crypto_pwhash(
        output: *mut u8,
        output_length: u64,
        password: *const c_char,
        password_length: u64,
        salt: *const u8,
        opslimit: u64,
        memlimit: usize,
        algorithm: c_int,
    ) -> c_int;
}

#[derive(Zeroize, ZeroizeOnDrop)]
struct Keys {
    xts: [u8; XTS_KEY_SIZE],
    mac: [u8; MAC_KEY_SIZE],
}

fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

fn fixed_data_size(data_size: u64) -> VaultResult<u64> {
    if data_size < SECTOR_SIZE as u64
        || data_size > MAX_DATA_SIZE
        || data_size % SECTOR_SIZE as u64 != 0
    {
        return Err(invalid("vault size must be a sector-aligned value between 4K and 16G").into());
    }
    data_size
        .checked_add(TAG_SIZE as u64)
        .ok_or_else(|| invalid("vault size is too large").into())
}

fn parse_size(text: &str) -> VaultResult<u64> {
    if text.is_empty() {
        return Err(invalid("vault size is empty").into());
    }

    let (digits, multiplier) = match text.as_bytes().last().copied() {
        Some(b'k' | b'K') => (&text[..text.len() - 1], 1024u64),
        Some(b'm' | b'M') => (&text[..text.len() - 1], 1024u64.pow(2)),
        Some(b'g' | b'G') => (&text[..text.len() - 1], 1024u64.pow(3)),
        Some(b'0'..=b'9') => (text, 1),
        _ => return Err(invalid("vault size suffix must be K, M, or G").into()),
    };

    let value: u64 = digits.parse().map_err(|_| invalid("invalid vault size"))?;
    let data_size = value
        .checked_mul(multiplier)
        .ok_or_else(|| invalid("vault size is too large"))?;
    if data_size < SECTOR_SIZE as u64
        || data_size > MAX_DATA_SIZE
        || data_size % SECTOR_SIZE as u64 != 0
    {
        return Err(invalid("vault size must be a sector-aligned value between 4K and 16G").into());
    }
    Ok(data_size)
}

fn image_data_size(image_size: u64) -> VaultResult<u64> {
    if image_size <= TAG_SIZE as u64 {
        return Err(invalid_data("vault file is too small").into());
    }
    let data_size = image_size - TAG_SIZE as u64;
    fixed_data_size(data_size)
        .map_err(|_| invalid_data("vault file has an invalid size").into())?;
    Ok(data_size)
}

fn inspect_image(path: &Path) -> VaultResult<(u64, u64)> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() {
        return Err(invalid_data("vault path is not a regular file").into());
    }
    let image_size = metadata.len();
    Ok((image_size, image_data_size(image_size)?))
}

fn read_password(fd: i32) -> VaultResult<Vec<u8>> {
    if fd < 0 {
        return Err(invalid("--password-fd is required").into());
    }

    let input = unsafe { File::from_raw_fd(fd) };
    let mut password = Vec::with_capacity(PASSWORD_MAX);
    input
        .take((PASSWORD_MAX + 2) as u64)
        .read_to_end(&mut password)?;
    if password.len() > PASSWORD_MAX + 1 {
        password.zeroize();
        return Err(invalid("password is too long").into());
    }
    while matches!(password.last(), Some(b'\n' | b'\r')) {
        password.pop();
    }
    if password.is_empty() {
        return Err(invalid("password cannot be empty").into());
    }
    if password.len() > PASSWORD_MAX || password.contains(&0) {
        password.zeroize();
        return Err(invalid("password is invalid").into());
    }
    Ok(password)
}

fn derive_keys(password: &[u8]) -> VaultResult<Keys> {
    if password.is_empty() || password.len() > PASSWORD_MAX {
        return Err(invalid("password length is invalid").into());
    }

    let mut material = [0u8; KEY_MATERIAL_SIZE];
    let result = unsafe {
        crypto_pwhash(
            material.as_mut_ptr(),
            material.len() as u64,
            password.as_ptr() as *const c_char,
            password.len() as u64,
            KDF_SALT.as_ptr(),
            ARGON2ID_OPSLIMIT,
            ARGON2ID_MEMLIMIT,
            ARGON2ID_ALGORITHM,
        )
    };
    if result != 0 {
        material.zeroize();
        return Err(io::Error::new(io::ErrorKind::Other, "Argon2id key derivation failed").into());
    }

    let mut xts = [0u8; XTS_KEY_SIZE];
    let mut mac = [0u8; MAC_KEY_SIZE];
    xts.copy_from_slice(&material[..XTS_KEY_SIZE]);
    mac.copy_from_slice(&material[XTS_KEY_SIZE..]);
    material.zeroize();
    Ok(Keys { xts, mac })
}

fn new_mac(key: &[u8; MAC_KEY_SIZE], image_size: u64) -> VaultResult<HmacSha256> {
    let mut mac = HmacSha256::new_from_slice(key)
        .map_err(|_| io::Error::new(io::ErrorKind::Other, "cannot initialize HMAC"))?;
    mac.update(HMAC_CONTEXT);
    mac.update(&image_size.to_le_bytes());
    Ok(mac)
}

fn constant_time_tag_matches(expected: &[u8], actual: &[u8; TAG_SIZE]) -> bool {
    expected.len() == TAG_SIZE && expected.ct_eq(actual.as_slice()).unwrap_u8() == 1
}

fn crypt_sector(
    key: &[u8; XTS_KEY_SIZE],
    sector: u64,
    input: &[u8; SECTOR_SIZE],
    mode: Mode,
) -> VaultResult<[u8; SECTOR_SIZE]> {
    let mut tweak = [0u8; 16];
    tweak[..8].copy_from_slice(&sector.to_le_bytes());

    let mut crypter = Crypter::new(Cipher::aes_256_xts(), mode, key, Some(&tweak))?;
    crypter.pad(false);
    let mut output = [0u8; SECTOR_SIZE + 32];
    let mut written = crypter.update(input, &mut output)?;
    let finalized = crypter.finalize(&mut output[written..])?;
    written += finalized;
    if written != SECTOR_SIZE {
        output.zeroize();
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "AES-XTS returned an unexpected sector length",
        )
        .into());
    }

    let mut result = [0u8; SECTOR_SIZE];
    result.copy_from_slice(&output[..SECTOR_SIZE]);
    output.zeroize();
    Ok(result)
}

struct LimitedWriter<W> {
    inner: W,
    limit: u64,
    written: u64,
}

impl<W: Write> Write for LimitedWriter<W> {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        let length = u64::try_from(buffer.len()).map_err(|_| invalid("archive is too large"))?;
        if self.written > self.limit.saturating_sub(length) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "wallet archive is too large for the vault",
            ));
        }
        let count = self.inner.write(buffer)?;
        self.written += count as u64;
        Ok(count)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

impl<W> LimitedWriter<W> {
    fn into_inner(self) -> W {
        self.inner
    }
}

fn validate_entry_path(path: &Path) -> VaultResult<()> {
    if path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, Component::ParentDir | Component::RootDir))
    {
        return Err(invalid_data("vault archive contains an unsafe path").into());
    }
    Ok(())
}

fn validate_archive(file: &mut File) -> VaultResult<()> {
    file.seek(SeekFrom::Start(0))?;
    let archive = Archive::new(&mut *file);
    for entry in archive.entries()? {
        let entry = entry?;
        validate_entry_path(&entry.path()?)?;
        let entry_type = entry.header().entry_type();
        if !(entry_type.is_file() || entry_type.is_dir()) {
            return Err(invalid_data("vault archive contains a non-file entry").into());
        }
    }
    file.seek(SeekFrom::Start(0))?;
    Ok(())
}

fn archive_source(source: &Path, maximum_size: u64) -> VaultResult<File> {
    if !fs::metadata(source)?.is_dir() {
        return Err(invalid("wallet source is not a directory").into());
    }

    let mut file = tempfile()?;
    {
        let limited = LimitedWriter {
            inner: &mut file,
            limit: maximum_size,
            written: 0,
        };
        let mut builder = Builder::new(limited);
        builder.append_dir_all(".", source)?;
        builder.finish()?;
        let mut limited = builder.into_inner()?;
        limited.flush()?;
    }
    file.sync_all()?;
    if file.metadata()?.len() > maximum_size {
        return Err(invalid("wallet archive is too large for the vault").into());
    }
    validate_archive(&mut file)?;
    file.seek(SeekFrom::Start(0))?;
    Ok(file)
}

fn random_suffix() -> VaultResult<String> {
    let mut bytes = [0u8; 16];
    rand_bytes(&mut bytes)?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn temporary_image_path(image: &Path) -> VaultResult<(PathBuf, File)> {
    let parent = image
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let name = image
        .file_name()
        .ok_or_else(|| invalid("vault path has no filename"))?
        .to_string_lossy();

    for _ in 0..16 {
        let candidate = parent.join(format!(".{name}.tmp-{}", random_suffix()?));
        match OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .mode(0o600)
            .open(&candidate)
        {
            Ok(file) => return Ok((candidate, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "cannot create a unique temporary vault",
    )
    .into())
}

#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;

fn sync_parent(path: &Path) -> VaultResult<()> {
    let parent = path
        .parent()
        .filter(|value| !value.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let directory = File::open(parent)?;
    match directory.sync_all() {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::InvalidInput => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn install_image(temp_path: &Path, image: &Path, create_new: bool) -> VaultResult<()> {
    if create_new {
        fs::hard_link(temp_path, image)?;
        fs::remove_file(temp_path)?;
    } else {
        fs::rename(temp_path, image)?;
    }
    sync_parent(image)
}

fn create_inner_header(archive_size: u64) -> VaultResult<[u8; INNER_HEADER_SIZE]> {
    let mut header = [0u8; INNER_HEADER_SIZE];
    rand_bytes(&mut header[32..])?;
    header[..INNER_MAGIC.len()].copy_from_slice(INNER_MAGIC);
    header[16..20].copy_from_slice(&1u32.to_le_bytes());
    header[20..24].copy_from_slice(&(SECTOR_SIZE as u32).to_le_bytes());
    header[24..32].copy_from_slice(&archive_size.to_le_bytes());
    Ok(header)
}

fn pack_image(
    image: &Path,
    data_size: u64,
    source: &Path,
    keys: &Keys,
    create_new: bool,
) -> VaultResult<()> {
    if create_new && fs::symlink_metadata(image).is_ok() {
        return Err(io::Error::new(io::ErrorKind::AlreadyExists, "vault already exists").into());
    }
    let image_size = fixed_data_size(data_size)?;
    if !create_new {
        let (existing_size, existing_data_size) = inspect_image(image)?;
        if existing_data_size != data_size {
            return Err(invalid("vault size cannot change during pack").into());
        }
        let _ = existing_size;
    }

    let maximum_archive_size = data_size
        .checked_sub(INNER_HEADER_SIZE as u64)
        .ok_or_else(|| invalid("vault is too small"))?;
    let mut archive = archive_source(source, maximum_archive_size)?;
    let archive_size = archive.metadata()?.len();
    let (temporary_path, mut output) = temporary_image_path(image)?;
    let result = (|| -> VaultResult<()> {
        let mut mac = new_mac(&keys.mac, image_size)?;
        let sector_count = data_size / SECTOR_SIZE as u64;
        let mut archive_remaining = archive_size;
        let mut plaintext = Zeroizing::new([0u8; SECTOR_SIZE]);

        for sector in 0..sector_count {
            rand_bytes(&mut plaintext)?;
            let offset = if sector == 0 { INNER_HEADER_SIZE } else { 0 };
            if sector == 0 {
                plaintext[..INNER_HEADER_SIZE].copy_from_slice(&create_inner_header(archive_size)?);
            }

            let mut position = offset;
            while position < SECTOR_SIZE && archive_remaining > 0 {
                let wanted =
                    usize::try_from(archive_remaining.min((SECTOR_SIZE - position) as u64))?;
                let count = archive.read(&mut plaintext[position..position + wanted])?;
                if count == 0 {
                    return Err(invalid_data("wallet archive ended unexpectedly").into());
                }
                position += count;
                archive_remaining -= count as u64;
            }

            let ciphertext =
                Zeroizing::new(crypt_sector(&keys.xts, sector, &plaintext, Mode::Encrypt)?);
            output.write_all(&*ciphertext)?;
            mac.update(&*ciphertext);
        }
        if archive_remaining != 0 {
            return Err(invalid_data("wallet archive was not fully encrypted").into());
        }

        let tag = mac.finalize().into_bytes();
        output.write_all(&tag)?;
        output.sync_all()?;
        Ok(())
    })();
    drop(archive);
    drop(output);

    if let Err(error) = result {
        let _ = fs::remove_file(&temporary_path);
        return Err(error);
    }
    install_image(&temporary_path, image, create_new)
}

fn verify_image(file: &mut File, image_size: u64, data_size: u64, keys: &Keys) -> VaultResult<()> {
    file.seek(SeekFrom::Start(0))?;
    let mut mac = new_mac(&keys.mac, image_size)?;
    let mut buffer = [0u8; 64 * 1024];
    let mut remaining = data_size;
    while remaining > 0 {
        let wanted = usize::try_from(remaining.min(buffer.len() as u64))?;
        file.read_exact(&mut buffer[..wanted])?;
        mac.update(&buffer[..wanted]);
        remaining -= wanted as u64;
    }
    let mut actual = [0u8; TAG_SIZE];
    file.read_exact(&mut actual)?;
    let mut expected = mac.finalize().into_bytes().to_vec();
    let matches = constant_time_tag_matches(&expected, &actual);
    buffer.zeroize();
    expected.zeroize();
    actual.zeroize();
    if !matches {
        return Err(
            invalid_data("vault authentication failed (wrong password or damaged file)").into(),
        );
    }
    Ok(())
}

fn decrypt_archive(file: &mut File, data_size: u64, keys: &Keys) -> VaultResult<File> {
    file.seek(SeekFrom::Start(0))?;
    let sector_count = data_size / SECTOR_SIZE as u64;
    let mut ciphertext = Zeroizing::new([0u8; SECTOR_SIZE]);
    let mut archive = tempfile()?;
    let mut archive_size = None;
    let mut remaining = 0u64;

    for sector in 0..sector_count {
        file.read_exact(&mut ciphertext)?;
        let plaintext =
            Zeroizing::new(crypt_sector(&keys.xts, sector, &ciphertext, Mode::Decrypt)?);
        if sector == 0 {
            if plaintext[..INNER_MAGIC.len()] != INNER_MAGIC[..]
                || u32::from_le_bytes(plaintext[16..20].try_into()?) != 1
                || u32::from_le_bytes(plaintext[20..24].try_into()?) != SECTOR_SIZE as u32
            {
                return Err(invalid_data("vault format is not recognized").into());
            }
            let size = u64::from_le_bytes(plaintext[24..32].try_into()?);
            let maximum = data_size - INNER_HEADER_SIZE as u64;
            if size > maximum {
                return Err(invalid_data("vault archive length is invalid").into());
            }
            archive_size = Some(size);
            remaining = size;
            let available = SECTOR_SIZE - INNER_HEADER_SIZE;
            let wanted = remaining.min(available as u64) as usize;
            archive.write_all(&plaintext[INNER_HEADER_SIZE..INNER_HEADER_SIZE + wanted])?;
            remaining -= wanted as u64;
        } else if remaining > 0 {
            let wanted = remaining.min(SECTOR_SIZE as u64) as usize;
            archive.write_all(&plaintext[..wanted])?;
            remaining -= wanted as u64;
        }
    }

    if archive_size.is_none() || remaining != 0 {
        return Err(invalid_data("vault archive is truncated").into());
    }
    archive.sync_all()?;
    archive.seek(SeekFrom::Start(0))?;
    validate_archive(&mut archive)?;
    archive.seek(SeekFrom::Start(0))?;
    Ok(archive)
}

fn unpack_archive(mut archive: File, destination: &Path) -> VaultResult<()> {
    if !fs::metadata(destination)?.is_dir() {
        return Err(invalid("wallet destination is not a directory").into());
    }
    if fs::read_dir(destination)?.next().transpose()?.is_some() {
        return Err(invalid("wallet destination must be empty").into());
    }

    let mut tar_archive = Archive::new(&mut archive);
    for entry in tar_archive.entries()? {
        let mut entry = entry?;
        validate_entry_path(&entry.path()?)?;
        let entry_type = entry.header().entry_type();
        if !(entry_type.is_file() || entry_type.is_dir()) {
            return Err(invalid_data("vault archive contains a non-file entry").into());
        }
        entry.unpack_in(destination)?;
    }
    Ok(())
}

fn unpack_image(image: &Path, destination: &Path, keys: &Keys) -> VaultResult<()> {
    let (image_size, data_size) = inspect_image(image)?;
    let mut file = File::open(image)?;
    verify_image(&mut file, image_size, data_size, keys)?;
    let archive = decrypt_archive(&mut file, data_size, keys)?;
    unpack_archive(archive, destination)
}

fn usage(program: &str) {
    eprintln!(
        "Usage:\n  {program} --password-fd FD create IMAGE SIZE SOURCE\n  {program} --password-fd FD pack IMAGE SOURCE\n  {program} --password-fd FD unpack IMAGE DESTINATION"
    );
}

fn run() -> VaultResult<()> {
    if unsafe { sodium_init() } < 0 {
        return Err(io::Error::new(io::ErrorKind::Other, "libsodium initialization failed").into());
    }

    let arguments: Vec<String> = env::args().skip(1).collect();
    if arguments.len() < 3 || arguments[0] != "--password-fd" {
        usage("mgla-vault");
        return Err(invalid("invalid command line").into());
    }
    let password_fd: i32 = arguments[1]
        .parse()
        .map_err(|_| invalid("invalid password fd"))?;
    let command = arguments[2].as_str();
    let expected_arguments = match command {
        "create" => 6,
        "pack" | "unpack" => 5,
        _ => {
            usage("mgla-vault");
            return Err(invalid("unknown command").into());
        }
    };
    if arguments.len() != expected_arguments {
        usage("mgla-vault");
        return Err(invalid("invalid command line").into());
    }

    let mut password = read_password(password_fd)?;
    let derived = derive_keys(&password);
    password.zeroize();
    let keys = derived?;

    match command {
        "create" => {
            let image = Path::new(&arguments[3]);
            let data_size = parse_size(&arguments[4])?;
            let source = Path::new(&arguments[5]);
            pack_image(image, data_size, source, &keys, true)
        }
        "pack" => {
            let image = Path::new(&arguments[3]);
            let source = Path::new(&arguments[4]);
            let (_, data_size) = inspect_image(image)?;
            pack_image(image, data_size, source, &keys, false)
        }
        "unpack" => {
            let image = Path::new(&arguments[3]);
            let destination = Path::new(&arguments[4]);
            unpack_image(image, destination, &keys)
        }
        _ => unreachable!(),
    }
}

fn main() {
    if let Err(error) = run() {
        eprintln!("mgla-vault: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    fn test_keys() -> Keys {
        unsafe {
            assert!(sodium_init() >= 0);
        }
        derive_keys(b"test-password-for-vault").expect("derive test keys")
    }

    #[test]
    fn parses_usable_capacity() {
        assert_eq!(
            parse_size("256M").expect("256M should parse"),
            256 * 1024 * 1024
        );
        assert!(parse_size("256M").unwrap() % SECTOR_SIZE as u64 == 0);
        assert!(parse_size("4097").is_err());
    }

    #[test]
    fn rejects_unsafe_archive_paths() {
        assert!(validate_entry_path(Path::new("../wallet")).is_err());
        assert!(validate_entry_path(Path::new("/wallet")).is_err());
        assert!(validate_entry_path(Path::new("wallet/name")).is_ok());
    }

    #[test]
    fn round_trip_rejects_tampering() {
        let root = tempdir().expect("test root");
        let source = root.path().join("source");
        let destination = root.path().join("destination");
        let image = root.path().join("wallets.mgla");
        fs::create_dir_all(source.join("alice")).expect("source directory");
        fs::create_dir(&destination).expect("destination directory");
        fs::write(source.join("alice/wallet.keys"), b"private test data").expect("wallet file");

        let keys = test_keys();
        pack_image(&image, 1024 * 1024, &source, &keys, true).expect("pack image");
        unpack_image(&image, &destination, &keys).expect("unpack image");
        assert_eq!(
            fs::read(destination.join("alice/wallet.keys")).expect("unpacked wallet"),
            b"private test data"
        );

        let mut bytes = fs::read(&image).expect("read image");
        bytes[0] ^= 0x01;
        fs::write(&image, &bytes).expect("tamper image");
        let tampered_destination = root.path().join("tampered");
        fs::create_dir(&tampered_destination).expect("tampered destination");
        assert!(unpack_image(&image, &tampered_destination, &keys).is_err());
    }
}
