use hmac::{Hmac, Mac};
use openssl::rand::rand_bytes;
use openssl::symm::{Cipher, Crypter, Mode};
use sha2::Sha256;
use std::env;
use std::error::Error;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::os::fd::FromRawFd;
use std::os::raw::{c_char, c_int, c_void};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use subtle::ConstantTimeEq;

#[cfg(unix)]
use std::net::Shutdown;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
#[cfg(unix)]
use std::os::unix::net::{UnixListener, UnixStream};
use tar::{Archive, Builder};
use tempfile::tempfile;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

type HmacSha256 = Hmac<Sha256>;
type VaultResult<T> = Result<T, Box<dyn Error>>;

const SECTOR_SIZE: usize = 4096;
const TAG_SIZE: usize = 32;
const SALT_SIZE: usize = 16;
const ENVELOPE_SECTOR_SIZE: usize = SECTOR_SIZE;
const ENVELOPE_SALT_OFFSET: usize = SECTOR_SIZE / 8;
const ENVELOPE_TAG_OFFSET: usize = SECTOR_SIZE * 5 / 8;
const INNER_HEADER_SIZE: usize = 64;
const XTS_KEY_SIZE: usize = 64;
const MAC_KEY_SIZE: usize = 32;
const KEY_MATERIAL_SIZE: usize = XTS_KEY_SIZE + MAC_KEY_SIZE;
const PASSWORD_MAX: usize = 512;
const MAX_VAULT_SIZE: u64 = 16 * 1024 * 1024 * 1024;
const ARGON2ID_OPSLIMIT: u64 = 4;
const ARGON2ID_MEMLIMIT: usize = 1024 * 1024 * 1024;
const ARGON2ID_ALGORITHM: c_int = 2;
const GENERATED_PASSWORD_CORE_LENGTH: usize = 47;
const GENERATED_PASSWORD_LENGTH: usize = GENERATED_PASSWORD_CORE_LENGTH + 1;
const GENERATED_PASSWORD_MIN_SPECIALS: usize = 7;
// These are public password-policy alphabets; characters are selected with
// the CSPRNG below and are not password or key material.
// codeql[rust/hard-coded-cryptographic-value]
const GENERATED_PASSWORD_LETTERS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const GENERATED_PASSWORD_ALPHABET: &[u8] =
    // codeql[rust/hard-coded-cryptographic-value]
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789<>*+!?_=#@%&";
const GENERATED_PASSWORD_SPECIALS: &[u8] = b"<>*+!?_=#@%&";
const HMAC_CONTEXT: &[u8] = b"MGLA-RAW-V3-HMAC";
const INNER_MAGIC: &[u8] = b"MGLA-RAW-V3";
const FORMAT_VERSION: u32 = 3;

#[link(name = "sodium")]
unsafe extern "C" {
    fn sodium_init() -> c_int;
    fn sodium_mlock(address: *mut c_void, length: usize) -> c_int;
    fn sodium_munlock(address: *mut c_void, length: usize) -> c_int;
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

struct LockedKeys {
    inner: Box<Keys>,
}

impl LockedKeys {
    fn new(keys: Keys) -> VaultResult<Self> {
        let mut inner = Box::new(keys);
        let address = inner.as_mut() as *mut Keys as *mut c_void;
        let result = unsafe { sodium_mlock(address, std::mem::size_of::<Keys>()) };
        if result != 0 {
            return Err(io::Error::other("cannot lock vault keys in memory").into());
        }
        Ok(Self { inner })
    }

    fn as_ref(&self) -> &Keys {
        &self.inner
    }
}

impl Drop for LockedKeys {
    fn drop(&mut self) {
        self.inner.zeroize();
        let address = self.inner.as_mut() as *mut Keys as *mut c_void;
        let _ = unsafe { sodium_munlock(address, std::mem::size_of::<Keys>()) };
    }
}

fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

fn validate_vault_size(image_size: u64) -> VaultResult<u64> {
    let minimum_size = (ENVELOPE_SECTOR_SIZE + SECTOR_SIZE) as u64;
    if image_size < minimum_size
        || image_size > MAX_VAULT_SIZE
        || !image_size.is_multiple_of(SECTOR_SIZE as u64)
    {
        return Err(invalid("vault size must be sector-aligned between 8K and 16G").into());
    }
    Ok(image_size)
}

fn validate_data_size(data_size: u64) -> VaultResult<u64> {
    if data_size < SECTOR_SIZE as u64
        || data_size > MAX_VAULT_SIZE - ENVELOPE_SECTOR_SIZE as u64
        || !data_size.is_multiple_of(SECTOR_SIZE as u64)
    {
        return Err(invalid("vault payload size is invalid").into());
    }
    Ok(data_size)
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
    let image_size = value
        .checked_mul(multiplier)
        .ok_or_else(|| invalid("vault size is too large"))?;
    validate_vault_size(image_size)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum VaultFormat {
    CurrentV3,
}

impl VaultFormat {
    fn version(self) -> u32 {
        FORMAT_VERSION
    }

    fn hmac_context(self) -> &'static [u8] {
        HMAC_CONTEXT
    }

    fn kdf_parameters(self) -> (u64, usize) {
        (ARGON2ID_OPSLIMIT, ARGON2ID_MEMLIMIT)
    }
}

#[derive(Clone, Copy)]
struct VaultLayout {
    format: VaultFormat,
    image_size: u64,
    data_size: u64,
    data_offset: u64,
    salt: [u8; SALT_SIZE],
}

impl VaultLayout {
    fn current(image_size: u64) -> VaultResult<Self> {
        validate_vault_size(image_size)?;
        let data_size = image_size
            .checked_sub(ENVELOPE_SECTOR_SIZE as u64)
            .ok_or_else(|| invalid("vault size is too small"))?;
        validate_data_size(data_size)?;
        let mut salt = [0u8; SALT_SIZE];
        rand_bytes(&mut salt)?;
        Ok(Self {
            format: VaultFormat::CurrentV3,
            image_size,
            data_size,
            data_offset: ENVELOPE_SECTOR_SIZE as u64,
            salt,
        })
    }

    fn from_image(image_size: u64, salt: [u8; SALT_SIZE]) -> VaultResult<Self> {
        validate_vault_size(image_size)?;
        let data_size = image_size
            .checked_sub(ENVELOPE_SECTOR_SIZE as u64)
            .ok_or_else(|| invalid_data("vault file is too small"))?;
        validate_data_size(data_size)
            .map_err(|_| invalid_data("vault file has an invalid size"))?;
        Ok(Self {
            format: VaultFormat::CurrentV3,
            image_size,
            data_size,
            data_offset: ENVELOPE_SECTOR_SIZE as u64,
            salt,
        })
    }
}

fn inspect_image(path: &Path) -> VaultResult<VaultLayout> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() {
        return Err(invalid_data("vault path is not a regular file").into());
    }
    let image_size = metadata.len();
    validate_vault_size(image_size).map_err(|_| invalid_data("vault file has an invalid size"))?;

    let mut file = File::open(path)?;
    let mut envelope = [0u8; ENVELOPE_SECTOR_SIZE];
    file.read_exact(&mut envelope)?;
    let salt: [u8; SALT_SIZE] = envelope[ENVELOPE_SALT_OFFSET..ENVELOPE_SALT_OFFSET + SALT_SIZE]
        .try_into()
        .map_err(|_| invalid_data("vault envelope salt has invalid length"))?;
    envelope.zeroize();
    VaultLayout::from_image(image_size, salt)
}

fn read_password(fd: i32) -> VaultResult<Zeroizing<Vec<u8>>> {
    if fd < 0 {
        return Err(invalid("--password-fd is required").into());
    }

    let input = unsafe { File::from_raw_fd(fd) };
    let mut password = Zeroizing::new(Vec::with_capacity(PASSWORD_MAX));
    input
        .take((PASSWORD_MAX + 2) as u64)
        .read_to_end(&mut password)?;
    if password.len() > PASSWORD_MAX + 1 {
        return Err(invalid("password is too long").into());
    }

    while matches!(password.last(), Some(b'\n' | b'\r')) {
        password.pop();
    }

    if password.is_empty() {
        return Err(invalid("password cannot be empty").into());
    }
    if password.len() > PASSWORD_MAX || password.contains(&0) {
        return Err(invalid("password is invalid").into());
    }

    Ok(password)
}

fn derive_keys(password: &[u8], layout: &VaultLayout) -> VaultResult<Keys> {
    if password.is_empty() || password.len() > PASSWORD_MAX {
        return Err(invalid("password length is invalid").into());
    }

    let (opslimit, memlimit) = layout.format.kdf_parameters();
    let mut material = [0u8; KEY_MATERIAL_SIZE];
    let result = unsafe {
        crypto_pwhash(
            material.as_mut_ptr(),
            material.len() as u64,
            password.as_ptr() as *const c_char,
            password.len() as u64,
            layout.salt.as_ptr(),
            opslimit,
            memlimit,
            ARGON2ID_ALGORITHM,
        )
    };
    if result != 0 {
        material.zeroize();
        return Err(io::Error::other("Argon2id key derivation failed").into());
    }

    let mut xts = [0u8; XTS_KEY_SIZE];
    let mut mac = [0u8; MAC_KEY_SIZE];
    xts.copy_from_slice(&material[..XTS_KEY_SIZE]);
    mac.copy_from_slice(&material[XTS_KEY_SIZE..]);
    material.zeroize();
    Ok(Keys { xts, mac })
}

fn new_mac(key: &[u8; MAC_KEY_SIZE], layout: &VaultLayout) -> VaultResult<HmacSha256> {
    let mut mac =
        HmacSha256::new_from_slice(key).map_err(|_| io::Error::other("cannot initialize HMAC"))?;
    mac.update(layout.format.hmac_context());
    mac.update(&layout.image_size.to_le_bytes());
    Ok(mac)
}

fn update_envelope_mac(mac: &mut HmacSha256, envelope: &[u8; ENVELOPE_SECTOR_SIZE]) {
    mac.update(&envelope[..ENVELOPE_TAG_OFFSET]);
    mac.update(&envelope[ENVELOPE_TAG_OFFSET + TAG_SIZE..]);
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
    let mut archive = Archive::new(&mut *file);
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

fn random_u32() -> VaultResult<u32> {
    let mut bytes = [0u8; std::mem::size_of::<u32>()];
    rand_bytes(&mut bytes)?;
    Ok(u32::from_le_bytes(bytes))
}

fn random_range(min: usize, max: usize) -> VaultResult<usize> {
    if min >= max {
        return Err(invalid("random range is invalid").into());
    }

    let range = max
        .checked_sub(min)
        .and_then(|value| value.checked_add(1))
        .ok_or_else(|| invalid("random range is too large"))?;
    let range = u64::try_from(range)?;
    let sample_space = 1u64 << u32::BITS;
    if range > sample_space {
        return Err(invalid("random range is too large").into());
    }

    let limit = (sample_space / range) * range - 1;
    loop {
        let value = u64::from(random_u32()?);
        if value <= limit {
            return Ok((value % range) as usize + min);
        }
    }
}

fn random_character(alphabet: &[u8]) -> VaultResult<u8> {
    if alphabet.len() < 2 {
        return Err(invalid("random alphabet is too short").into());
    }

    let index = random_range(0, alphabet.len() - 1)?;
    Ok(alphabet[index])
}

fn permute_middle(password: &mut [u8]) -> VaultResult<()> {
    if password.len() < 2 {
        return Ok(());
    }

    let mut index = password.len() - 1;
    while index > 0 {
        let random_index = random_range(0, index)?;
        password.swap(index, random_index);
        index -= 1;
    }

    Ok(())
}

fn generate_vault_password() -> VaultResult<Zeroizing<Vec<u8>>> {
    let mut used = [false; 256];
    let mut used_special = [false; 256];
    let first = random_character(GENERATED_PASSWORD_LETTERS)?;
    let mut password = Zeroizing::new(vec![first]);
    let mut special_count = 0usize;

    used[first as usize] = true;

    while password.len() < GENERATED_PASSWORD_CORE_LENGTH
        || special_count < GENERATED_PASSWORD_MIN_SPECIALS
    {
        let character = random_character(GENERATED_PASSWORD_ALPHABET)?;
        let character_index = character as usize;

        if used[character_index] {
            continue;
        }

        used[character_index] = true;
        if GENERATED_PASSWORD_SPECIALS.contains(&character) && !used_special[character_index] {
            used_special[character_index] = true;
            special_count += 1;
        }

        password.push(character);
        if password.len() == GENERATED_PASSWORD_CORE_LENGTH
            && special_count < GENERATED_PASSWORD_MIN_SPECIALS
        {
            password.as_mut_slice().zeroize();
            password.clear();
            used = [false; 256];
            used_special = [false; 256];
            used[first as usize] = true;
            special_count = 0;
            password.push(first);
        }
    }

    let last = loop {
        let character = random_character(GENERATED_PASSWORD_LETTERS)?;
        if !used[character as usize] {
            break character;
        }
    };
    password.push(last);

    let middle_end = password.len() - 1;
    for _ in 0..5 {
        let password_slice = password.as_mut_slice();
        permute_middle(&mut password_slice[1..middle_end])?;
    }

    if password.len() != GENERATED_PASSWORD_LENGTH
        || special_count < GENERATED_PASSWORD_MIN_SPECIALS
    {
        return Err(invalid("generated password does not match policy").into());
    }

    Ok(password)
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

fn create_inner_header(archive_size: u64, version: u32) -> VaultResult<[u8; INNER_HEADER_SIZE]> {
    let mut header = [0u8; INNER_HEADER_SIZE];
    rand_bytes(&mut header[32..])?;
    header[..INNER_MAGIC.len()].copy_from_slice(INNER_MAGIC);
    header[16..20].copy_from_slice(&version.to_le_bytes());
    header[20..24].copy_from_slice(&(SECTOR_SIZE as u32).to_le_bytes());
    header[24..32].copy_from_slice(&archive_size.to_le_bytes());
    Ok(header)
}

fn pack_image(
    image: &Path,
    data_size: u64,
    source: &Path,
    layout: &VaultLayout,
    keys: &Keys,
    create_new: bool,
) -> VaultResult<()> {
    if create_new && fs::symlink_metadata(image).is_ok() {
        return Err(io::Error::new(io::ErrorKind::AlreadyExists, "vault already exists").into());
    }
    validate_data_size(data_size)?;
    if layout.data_size != data_size {
        return Err(invalid("vault layout and data size do not match").into());
    }
    if !create_new {
        let existing = inspect_image(image)?;
        if existing.format != layout.format
            || existing.image_size != layout.image_size
            || existing.data_size != data_size
            || existing.salt != layout.salt
        {
            return Err(invalid_data("vault image changed during pack").into());
        }
        let mut existing_file = File::open(image)?;
        verify_image(&mut existing_file, &existing, keys)?;
    }

    let maximum_archive_size = data_size
        .checked_sub(INNER_HEADER_SIZE as u64)
        .ok_or_else(|| invalid("vault is too small"))?;
    let mut archive = archive_source(source, maximum_archive_size)?;
    let archive_size = archive.metadata()?.len();
    let (temporary_path, mut output) = temporary_image_path(image)?;
    let result = (|| -> VaultResult<()> {
        let mut envelope = Zeroizing::new([0u8; ENVELOPE_SECTOR_SIZE]);
        rand_bytes(&mut envelope[..])?;
        envelope[ENVELOPE_SALT_OFFSET..ENVELOPE_SALT_OFFSET + SALT_SIZE]
            .copy_from_slice(&layout.salt);

        let mut mac = new_mac(&keys.mac, layout)?;
        update_envelope_mac(&mut mac, &envelope);
        output.write_all(&*envelope)?;

        let sector_count = data_size / SECTOR_SIZE as u64;
        let mut archive_remaining = archive_size;
        let mut plaintext = Zeroizing::new([0u8; SECTOR_SIZE]);

        for sector in 0..sector_count {
            rand_bytes(&mut plaintext[..])?;
            let offset = if sector == 0 { INNER_HEADER_SIZE } else { 0 };
            if sector == 0 {
                plaintext[..INNER_HEADER_SIZE]
                    .copy_from_slice(&create_inner_header(archive_size, layout.format.version())?);
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
        output.seek(SeekFrom::Start(ENVELOPE_TAG_OFFSET as u64))?;
        output.write_all(&tag)?;
        if output.metadata()?.len() != layout.image_size {
            return Err(invalid_data("vault image has an unexpected size").into());
        }
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

fn verify_image(file: &mut File, layout: &VaultLayout, keys: &Keys) -> VaultResult<()> {
    file.seek(SeekFrom::Start(0))?;
    let mut envelope = Zeroizing::new([0u8; ENVELOPE_SECTOR_SIZE]);
    file.read_exact(&mut envelope[..])?;

    let mut stored_salt = [0u8; SALT_SIZE];
    stored_salt.copy_from_slice(&envelope[ENVELOPE_SALT_OFFSET..ENVELOPE_SALT_OFFSET + SALT_SIZE]);
    let salt_matches = layout.salt.ct_eq(stored_salt.as_slice()).unwrap_u8() == 1;
    stored_salt.zeroize();
    if !salt_matches {
        return Err(invalid_data("vault salt does not match its layout").into());
    }

    let mut actual = [0u8; TAG_SIZE];
    actual.copy_from_slice(&envelope[ENVELOPE_TAG_OFFSET..ENVELOPE_TAG_OFFSET + TAG_SIZE]);
    let mut mac = new_mac(&keys.mac, layout)?;
    update_envelope_mac(&mut mac, &envelope);

    file.seek(SeekFrom::Start(layout.data_offset))?;
    let mut buffer = [0u8; 64 * 1024];
    let mut remaining = layout.data_size;
    while remaining > 0 {
        let wanted = usize::try_from(remaining.min(buffer.len() as u64))?;
        file.read_exact(&mut buffer[..wanted])?;
        mac.update(&buffer[..wanted]);
        remaining -= wanted as u64;
    }

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

fn decrypt_archive(file: &mut File, layout: &VaultLayout, keys: &Keys) -> VaultResult<File> {
    file.seek(SeekFrom::Start(layout.data_offset))?;
    let sector_count = layout.data_size / SECTOR_SIZE as u64;
    let mut ciphertext = Zeroizing::new([0u8; SECTOR_SIZE]);
    let mut archive = tempfile()?;
    let mut archive_size = None;
    let mut remaining = 0u64;

    for sector in 0..sector_count {
        file.read_exact(&mut ciphertext[..])?;
        let plaintext =
            Zeroizing::new(crypt_sector(&keys.xts, sector, &ciphertext, Mode::Decrypt)?);
        if sector == 0 {
            if plaintext[..INNER_MAGIC.len()] != INNER_MAGIC[..]
                || u32::from_le_bytes(plaintext[16..20].try_into()?) != layout.format.version()
                || u32::from_le_bytes(plaintext[20..24].try_into()?) != SECTOR_SIZE as u32
            {
                return Err(invalid_data("vault format is not recognized").into());
            }
            let size = u64::from_le_bytes(plaintext[24..32].try_into()?);
            let maximum = layout.data_size - INNER_HEADER_SIZE as u64;
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

fn unpack_image(
    image: &Path,
    destination: &Path,
    layout: &VaultLayout,
    keys: &Keys,
) -> VaultResult<()> {
    let mut file = File::open(image)?;
    verify_image(&mut file, layout, keys)?;
    let archive = decrypt_archive(&mut file, layout, keys)?;
    unpack_archive(archive, destination)
}

#[cfg(unix)]
struct VaultSession {
    image: PathBuf,
    wallet_root: PathBuf,
    layout: VaultLayout,
    keys: LockedKeys,
}

#[cfg(unix)]
impl VaultSession {
    fn image_matches_layout(&self) -> VaultResult<()> {
        let current = inspect_image(&self.image)?;
        if current.format != self.layout.format
            || current.data_size != self.layout.data_size
            || current.salt != self.layout.salt
        {
            return Err(invalid_data("vault image changed during the session").into());
        }
        Ok(())
    }

    fn pack(&self) -> VaultResult<()> {
        self.image_matches_layout()?;
        pack_image(
            &self.image,
            self.layout.data_size,
            &self.wallet_root,
            &self.layout,
            self.keys.as_ref(),
            false,
        )
    }

    fn unpack(&self) -> VaultResult<()> {
        self.image_matches_layout()?;
        unpack_image(
            &self.image,
            &self.wallet_root,
            &self.layout,
            self.keys.as_ref(),
        )
    }

    fn serve(self, listener: UnixListener) -> VaultResult<()> {
        for incoming in listener.incoming() {
            let mut stream = incoming?;
            let command = match read_session_command(&mut stream) {
                Ok(command) => command,
                Err(_) => continue,
            };
            let should_stop = command == "shutdown";

            let result = match command.as_str() {
                "pack" => self.pack(),
                "unpack" => self.unpack(),
                "shutdown" => Ok(()),
                _ => Err(invalid("unknown vault session command").into()),
            };

            write_session_response(&mut stream, &result)?;
            if should_stop {
                return Ok(());
            }
        }

        Ok(())
    }
}

#[cfg(unix)]
fn read_session_command(stream: &mut UnixStream) -> VaultResult<String> {
    let mut command = String::new();
    BufReader::new(stream).take(64).read_line(&mut command)?;

    let command = command.trim_end_matches(['\r', '\n']).to_owned();
    if command.is_empty() {
        return Err(invalid("vault session command is empty").into());
    }
    Ok(command)
}

#[cfg(unix)]
fn write_session_response(stream: &mut UnixStream, result: &VaultResult<()>) -> VaultResult<()> {
    match result {
        Ok(()) => stream.write_all(b"OK\n")?,
        Err(error) => {
            let message = error.to_string().replace(['\r', '\n'], " ");
            stream.write_all(b"ERR ")?;
            stream.write_all(message.as_bytes())?;
            stream.write_all(b"\n")?;
        }
    }
    stream.flush()?;
    Ok(())
}

#[cfg(unix)]
fn bind_session_socket(socket: &Path) -> VaultResult<UnixListener> {
    if fs::symlink_metadata(socket).is_ok() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "vault session socket already exists",
        )
        .into());
    }

    let listener = UnixListener::bind(socket)?;
    fs::set_permissions(socket, fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

#[cfg(unix)]
fn run_vault_session(image: &Path, wallet_root: &Path, socket: &Path) -> VaultResult<()> {
    let layout = inspect_image(image)?;
    let password = read_tty_password()?;
    let keys = derive_keys(&password, &layout)?;
    let keys = LockedKeys::new(keys)?;
    drop(password);

    let listener = bind_session_socket(socket)?;
    let session = VaultSession {
        image: image.to_owned(),
        wallet_root: wallet_root.to_owned(),
        layout,
        keys,
    };
    let result = session.serve(listener);
    let _ = fs::remove_file(socket);
    result
}

#[cfg(unix)]
fn session_request(socket: &Path, command: &str) -> VaultResult<()> {
    if !matches!(command, "pack" | "unpack" | "shutdown") {
        return Err(invalid("unknown vault session command").into());
    }

    let mut stream = UnixStream::connect(socket)?;
    stream.write_all(command.as_bytes())?;
    stream.write_all(b"\n")?;
    stream.shutdown(Shutdown::Write)?;

    let mut response = String::new();
    stream.take(4096).read_to_string(&mut response)?;
    let response = response.trim_end();
    if response == "OK" {
        return Ok(());
    }

    let message = response
        .strip_prefix("ERR ")
        .unwrap_or("invalid response from vault session");
    Err(invalid_data(message.to_owned()).into())
}

struct TtyEchoGuard {
    state: String,
}

impl TtyEchoGuard {
    fn disable(tty: &File) -> VaultResult<Self> {
        let saved = Command::new("stty")
            .arg("-g")
            .stdin(Stdio::from(tty.try_clone()?))
            .output()?;
        if !saved.status.success() {
            return Err(invalid("cannot read terminal state").into());
        }

        let state = String::from_utf8(saved.stdout)
            .map_err(|_| invalid("terminal state is not valid UTF-8"))?;
        let state = state.trim().to_owned();
        if state.is_empty() {
            return Err(invalid("terminal state is empty").into());
        }

        let disabled = Command::new("stty")
            .arg("-echo")
            .stdin(Stdio::from(tty.try_clone()?))
            .status()?;
        if !disabled.success() {
            return Err(invalid("cannot disable terminal echo").into());
        }

        Ok(Self { state })
    }
}

impl Drop for TtyEchoGuard {
    fn drop(&mut self) {
        let Ok(tty) = OpenOptions::new().read(true).write(true).open("/dev/tty") else {
            return;
        };
        let _ = Command::new("stty")
            .arg(&self.state)
            .stdin(Stdio::from(tty))
            .status();
    }
}

fn open_tty() -> VaultResult<File> {
    Ok(OpenOptions::new().read(true).write(true).open("/dev/tty")?)
}

fn read_tty_line(tty: &mut File, maximum: usize) -> VaultResult<Zeroizing<Vec<u8>>> {
    let mut line = Zeroizing::new(Vec::with_capacity(maximum.min(64)));
    let mut too_long = false;

    loop {
        let mut byte = [0u8; 1];
        tty.read_exact(&mut byte)?;
        if matches!(byte[0], b'\n' | b'\r') {
            break;
        }

        if line.len() < maximum {
            line.push(byte[0]);
        } else {
            too_long = true;
        }
    }

    if too_long {
        return Err(invalid("input is too long").into());
    }
    if line.is_empty() {
        return Err(invalid("input cannot be empty").into());
    }
    if line.contains(&0) {
        return Err(invalid("input contains NUL").into());
    }

    Ok(line)
}

fn read_tty_password() -> VaultResult<Zeroizing<Vec<u8>>> {
    let mut tty = open_tty()?;
    tty.write_all(b"Vault password: ")?;
    tty.flush()?;

    let password = {
        let echo_guard = TtyEchoGuard::disable(&tty)?;
        let result = read_tty_line(&mut tty, PASSWORD_MAX);
        drop(echo_guard);
        result?
    };

    tty.write_all(b"\n")?;
    tty.flush()?;
    Ok(password)
}

fn read_tty_confirmation(tty: &mut File) -> VaultResult<bool> {
    let mut response = Vec::with_capacity(4);
    let mut too_long = false;

    loop {
        let mut byte = [0u8; 1];
        tty.read_exact(&mut byte)?;
        if matches!(byte[0], b'\n' | b'\r') {
            break;
        }

        if response.len() < 16 {
            response.push(byte[0]);
        } else {
            too_long = true;
        }
    }

    if too_long {
        return Ok(false);
    }

    Ok(response.as_slice() == b"y" || response.as_slice() == b"Y")
}

fn prepare_generated_vault(
    image: &Path,
    image_size: u64,
    source: &Path,
) -> VaultResult<(VaultLayout, LockedKeys)> {
    if fs::symlink_metadata(image).is_ok() {
        return Err(io::Error::new(io::ErrorKind::AlreadyExists, "vault already exists").into());
    }

    let mut tty = open_tty()?;
    let password = generate_vault_password()?;
    tty.write_all(b"Vault password (save it now):\n")?;
    tty.write_all(password.as_slice())?;
    tty.write_all(b"\n\nI saved the password. Continue? [y/N]: ")?;
    tty.flush()?;

    if !read_tty_confirmation(&mut tty)? {
        tty.write_all(b"\nVault creation cancelled.\n")?;
        tty.flush()?;
        return Err(io::Error::new(io::ErrorKind::Interrupted, "vault creation cancelled").into());
    }

    tty.write_all(b"\n")?;
    tty.flush()?;
    drop(tty);

    let layout = VaultLayout::current(image_size)?;
    let raw_keys = derive_keys(&password, &layout)?;
    let keys = LockedKeys::new(raw_keys)?;
    drop(password);
    pack_image(
        image,
        layout.data_size,
        source,
        &layout,
        keys.as_ref(),
        true,
    )?;
    Ok((layout, keys))
}

fn create_generated_vault(image: &Path, image_size: u64, source: &Path) -> VaultResult<()> {
    let (_layout, _keys) = prepare_generated_vault(image, image_size, source)?;
    Ok(())
}

#[cfg(unix)]
fn create_generated_vault_session(
    image: &Path,
    image_size: u64,
    source: &Path,
    wallet_root: &Path,
    socket: &Path,
) -> VaultResult<()> {
    let (layout, keys) = prepare_generated_vault(image, image_size, source)?;
    let listener = bind_session_socket(socket)?;
    let session = VaultSession {
        image: image.to_owned(),
        wallet_root: wallet_root.to_owned(),
        layout,
        keys,
    };
    let result = session.serve(listener);
    let _ = fs::remove_file(socket);
    result
}

fn usage(program: &str) {
    eprintln!(
        "Usage:\n  {program} --password-fd FD create IMAGE SIZE SOURCE\n  {program} --password-fd FD pack IMAGE SOURCE\n  {program} --password-fd FD unpack IMAGE DESTINATION\n  {program} --tty-password create IMAGE SIZE SOURCE\n  {program} --tty-password pack IMAGE SOURCE\n  {program} --tty-password unpack IMAGE DESTINATION\n  {program} create-generated IMAGE SIZE SOURCE\n  {program} session-open IMAGE WALLET_ROOT SOCKET\n  {program} session-create-generated IMAGE SIZE SOURCE WALLET_ROOT SOCKET\n  {program} session-request SOCKET COMMAND"
    );
}

fn run() -> VaultResult<()> {
    if unsafe { sodium_init() } < 0 {
        return Err(io::Error::other("libsodium initialization failed").into());
    }

    let arguments: Vec<String> = env::args().skip(1).collect();
    match arguments.first().map(String::as_str) {
        Some("create-generated") => {
            if arguments.len() != 4 {
                usage("mgla-vault");
                return Err(invalid("invalid command line").into());
            }

            let image = Path::new(&arguments[1]);
            let image_size = parse_size(&arguments[2])?;
            let source = Path::new(&arguments[3]);
            return create_generated_vault(image, image_size, source);
        }
        Some("session-open") => {
            if arguments.len() != 4 {
                usage("mgla-vault");
                return Err(invalid("invalid command line").into());
            }

            return run_vault_session(
                Path::new(&arguments[1]),
                Path::new(&arguments[2]),
                Path::new(&arguments[3]),
            );
        }
        Some("session-create-generated") => {
            if arguments.len() != 6 {
                usage("mgla-vault");
                return Err(invalid("invalid command line").into());
            }

            let image = Path::new(&arguments[1]);
            let image_size = parse_size(&arguments[2])?;
            let source = Path::new(&arguments[3]);
            let wallet_root = Path::new(&arguments[4]);
            let socket = Path::new(&arguments[5]);
            return create_generated_vault_session(image, image_size, source, wallet_root, socket);
        }
        Some("session-request") => {
            if arguments.len() != 3 {
                usage("mgla-vault");
                return Err(invalid("invalid command line").into());
            }

            return session_request(Path::new(&arguments[1]), &arguments[2]);
        }
        _ => {}
    }

    if arguments.is_empty() {
        usage("mgla-vault");
        return Err(invalid("invalid command line").into());
    }

    let (command_index, password_fd) = if arguments[0] == "--password-fd" {
        if arguments.len() < 3 {
            usage("mgla-vault");
            return Err(invalid("invalid command line").into());
        }

        let fd = arguments[1]
            .parse()
            .map_err(|_| invalid("invalid password fd"))?;
        (2usize, Some(fd))
    } else if arguments[0] == "--tty-password" {
        if arguments.len() < 2 {
            usage("mgla-vault");
            return Err(invalid("invalid command line").into());
        }
        (1usize, None)
    } else {
        usage("mgla-vault");
        return Err(invalid("invalid command line").into());
    };

    let command = arguments[command_index].as_str();
    let command_arguments = match command {
        "create" => 3usize,
        "pack" | "unpack" => 2usize,
        _ => {
            usage("mgla-vault");
            return Err(invalid("unknown command").into());
        }
    };
    let expected_arguments = command_index + 1 + command_arguments;
    if arguments.len() != expected_arguments {
        usage("mgla-vault");
        return Err(invalid("invalid command line").into());
    }

    let mut password = match password_fd {
        Some(fd) => read_password(fd)?,
        None => read_tty_password()?,
    };
    let result: VaultResult<()> = (|| match command {
        "create" => {
            let image = Path::new(&arguments[command_index + 1]);
            let image_size = parse_size(&arguments[command_index + 2])?;
            let source = Path::new(&arguments[command_index + 3]);
            let layout = VaultLayout::current(image_size)?;
            let keys = derive_keys(&password, &layout)?;
            pack_image(image, layout.data_size, source, &layout, &keys, true)
        }
        "pack" => {
            let image = Path::new(&arguments[command_index + 1]);
            let source = Path::new(&arguments[command_index + 2]);
            let layout = inspect_image(image)?;
            let keys = derive_keys(&password, &layout)?;
            pack_image(image, layout.data_size, source, &layout, &keys, false)
        }
        "unpack" => {
            let image = Path::new(&arguments[command_index + 1]);
            let destination = Path::new(&arguments[command_index + 2]);
            let layout = inspect_image(image)?;
            let keys = derive_keys(&password, &layout)?;
            unpack_image(image, destination, &layout, &keys)
        }
        _ => unreachable!(),
    })();
    password.zeroize();
    result
}

fn main() {
    if let Err(error) = run() {
        if let Some(io_error) = error.downcast_ref::<io::Error>() {
            if io_error.kind() == io::ErrorKind::Interrupted {
                std::process::exit(2);
            }
        }
        eprintln!("mgla-vault: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::Once;
    use tempfile::tempdir;

    fn test_keys() -> Keys {
        let mut xts = [0x11; XTS_KEY_SIZE];
        xts[XTS_KEY_SIZE / 2..].fill(0x22);
        Keys {
            xts,
            mac: [0x33; MAC_KEY_SIZE],
        }
    }

    fn init_sodium() {
        static INIT: Once = Once::new();
        INIT.call_once(|| {
            assert!(unsafe { sodium_init() } >= 0);
        });
    }

    #[test]
    fn parses_usable_capacity() {
        assert_eq!(
            parse_size("256M").expect("256M should parse"),
            256 * 1024 * 1024
        );
        assert!(parse_size("256M")
            .unwrap()
            .is_multiple_of(SECTOR_SIZE as u64));
        assert!(parse_size("8K").is_ok());
        assert!(parse_size("4K").is_err());
        assert!(parse_size("4097").is_err());
    }

    #[test]
    fn rejects_unsafe_archive_paths() {
        assert!(validate_entry_path(Path::new("../wallet")).is_err());
        assert!(validate_entry_path(Path::new("/wallet")).is_err());
        assert!(validate_entry_path(Path::new("wallet/name")).is_ok());
    }

    #[test]
    fn current_layout_uses_unique_salts() {
        let first = VaultLayout::current(1024 * 1024).expect("first layout");
        let second = VaultLayout::current(1024 * 1024).expect("second layout");
        assert_ne!(first.salt, second.salt);
        assert_eq!(first.salt.len(), 16);
        assert_eq!(first.image_size, 1024 * 1024);
        assert_eq!(first.data_size, 1024 * 1024 - ENVELOPE_SECTOR_SIZE as u64);
        assert_eq!(first.image_size, second.image_size);
        assert_eq!(first.data_offset, ENVELOPE_SECTOR_SIZE as u64);
    }

    #[test]
    fn argon2id_derives_stable_separate_keys() {
        init_sodium();
        let layout = VaultLayout::from_image(1024 * 1024, [0xA5; SALT_SIZE]).expect("fixed layout");
        assert_eq!(
            layout.format.kdf_parameters(),
            (ARGON2ID_OPSLIMIT, ARGON2ID_MEMLIMIT)
        );

        let first = derive_keys(b"test-password", &layout).expect("derive first keys");
        let second = derive_keys(b"test-password", &layout).expect("derive same keys");
        let changed = derive_keys(b"other-password", &layout).expect("derive changed keys");
        let changed_salt_layout =
            VaultLayout::from_image(1024 * 1024, [0x5A; SALT_SIZE]).expect("changed salt layout");
        let changed_salt =
            derive_keys(b"test-password", &changed_salt_layout).expect("derive changed salt keys");
        assert_eq!(first.xts.len(), 64);
        assert_eq!(first.mac.len(), 32);
        assert_eq!(first.xts.len() + first.mac.len(), 96);

        assert_eq!(first.xts, second.xts);
        assert_eq!(first.mac, second.mac);
        assert_ne!(first.xts, changed.xts);
        assert_ne!(first.mac, changed.mac);
        assert_ne!(first.xts, changed_salt.xts);
        assert_ne!(first.mac, changed_salt.mac);
        assert_ne!(&first.xts[..MAC_KEY_SIZE], first.mac.as_slice());
        assert_ne!(first.xts, [0u8; XTS_KEY_SIZE]);
        assert_ne!(first.mac, [0u8; MAC_KEY_SIZE]);
    }

    #[test]
    fn aes_xts_uses_4k_sector_tweaks() {
        let keys = test_keys();
        let plaintext = [0xA7; SECTOR_SIZE];
        let sector_zero =
            crypt_sector(&keys.xts, 0, &plaintext, Mode::Encrypt).expect("encrypt sector zero");
        let sector_one =
            crypt_sector(&keys.xts, 1, &plaintext, Mode::Encrypt).expect("encrypt sector one");
        assert_ne!(sector_zero, sector_one);
        assert_eq!(
            crypt_sector(&keys.xts, 0, &sector_zero, Mode::Decrypt).expect("decrypt sector zero"),
            plaintext
        );
        assert_eq!(
            crypt_sector(&keys.xts, 1, &sector_one, Mode::Decrypt).expect("decrypt sector one"),
            plaintext
        );
        let wrong_tweak =
            crypt_sector(&keys.xts, 1, &sector_zero, Mode::Decrypt).expect("wrong tweak");
        assert_ne!(wrong_tweak, plaintext);
    }

    #[test]
    fn hmac_sha256_covers_envelope_and_ciphertext() {
        let keys = test_keys();
        let layout = VaultLayout::from_image(1024 * 1024, [0xA5; SALT_SIZE]).expect("fixed layout");
        let mut envelope = [0x19u8; ENVELOPE_SECTOR_SIZE];
        envelope[ENVELOPE_SALT_OFFSET..ENVELOPE_SALT_OFFSET + SALT_SIZE]
            .copy_from_slice(&layout.salt);
        let ciphertext = [0x2Bu8; SECTOR_SIZE];

        let tag = |envelope: &[u8; ENVELOPE_SECTOR_SIZE], ciphertext: &[u8; SECTOR_SIZE]| {
            let mut mac = new_mac(&keys.mac, &layout).expect("initialize HMAC");
            update_envelope_mac(&mut mac, envelope);
            mac.update(ciphertext);
            mac.finalize().into_bytes()
        };
        let expected = tag(&envelope, &ciphertext);
        assert_eq!(expected.len(), TAG_SIZE);

        let mut altered_envelope = envelope;
        altered_envelope[0] ^= 0x01;
        assert_ne!(expected, tag(&altered_envelope, &ciphertext));

        let mut altered_ciphertext = ciphertext;
        altered_ciphertext[0] ^= 0x01;
        assert_ne!(expected, tag(&envelope, &altered_ciphertext));
    }

    #[test]
    fn generated_password_matches_policy() {
        let password = generate_vault_password().expect("password generation");
        assert_eq!(password.len(), GENERATED_PASSWORD_LENGTH);
        assert!(GENERATED_PASSWORD_LETTERS.contains(&password[0]));
        assert!(GENERATED_PASSWORD_LETTERS.contains(password.last().expect("last character")));

        let mut used = [false; 256];
        let mut special_count = 0usize;
        for &character in password.iter() {
            assert!(GENERATED_PASSWORD_ALPHABET.contains(&character));
            assert!(!used[character as usize]);
            used[character as usize] = true;
            if GENERATED_PASSWORD_SPECIALS.contains(&character) {
                special_count += 1;
            }
        }
        assert!(special_count >= GENERATED_PASSWORD_MIN_SPECIALS);
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
        let layout = VaultLayout::current(1024 * 1024).expect("current layout");
        pack_image(&image, layout.data_size, &source, &layout, &keys, true).expect("pack image");
        assert_eq!(
            fs::metadata(&image).expect("image metadata").len(),
            layout.image_size
        );
        let inspected = inspect_image(&image).expect("inspect image");
        assert_eq!(inspected.image_size, layout.image_size);
        assert_eq!(inspected.data_size, layout.data_size);
        assert_eq!(inspected.salt, layout.salt);
        unpack_image(&image, &destination, &layout, &keys).expect("unpack image");
        assert_eq!(
            fs::read(destination.join("alice/wallet.keys")).expect("unpacked wallet"),
            b"private test data"
        );

        let persisted_salt = inspected.salt;
        pack_image(&image, layout.data_size, &source, &layout, &keys, false).expect("repack image");
        let repacked = inspect_image(&image).expect("inspect repacked image");
        assert_eq!(repacked.salt, persisted_salt);
        assert_eq!(repacked.data_size, layout.data_size);
        let wrong_keys = Keys {
            xts: [0x44; XTS_KEY_SIZE],
            mac: [0x55; MAC_KEY_SIZE],
        };
        let original_image = fs::read(&image).expect("read original image");
        assert!(pack_image(
            &image,
            layout.data_size,
            &source,
            &layout,
            &wrong_keys,
            false
        )
        .is_err());
        assert_eq!(
            fs::read(&image).expect("read image after rejected pack"),
            original_image
        );
        let mut bytes = fs::read(&image).expect("read image");
        bytes[0] ^= 0x01;
        fs::write(&image, &bytes).expect("tamper image");
        let tampered_destination = root.path().join("tampered");
        fs::create_dir(&tampered_destination).expect("tampered destination");
        assert!(unpack_image(&image, &tampered_destination, &layout, &keys).is_err());
        assert!(fs::read_dir(&tampered_destination)
            .expect("read tampered destination")
            .next()
            .is_none());

        let mut tag_bytes = original_image.clone();
        tag_bytes[ENVELOPE_TAG_OFFSET] ^= 0x01;
        fs::write(&image, &tag_bytes).expect("tamper authentication tag");
        let tag_tampered_destination = root.path().join("tag-tampered");
        fs::create_dir(&tag_tampered_destination).expect("tag destination");
        assert!(unpack_image(&image, &tag_tampered_destination, &layout, &keys).is_err());
        assert!(fs::read_dir(&tag_tampered_destination)
            .expect("read tag destination")
            .next()
            .is_none());

        fs::write(&image, &original_image).expect("restore original image");
        let mut ciphertext_bytes = original_image.clone();
        ciphertext_bytes[ENVELOPE_SECTOR_SIZE] ^= 0x01;
        fs::write(&image, &ciphertext_bytes).expect("tamper ciphertext");
        let invalid_destination = root.path().join("not-created");
        let authentication_error = unpack_image(&image, &invalid_destination, &layout, &keys)
            .expect_err("tampered ciphertext must fail authentication first");
        assert!(
            authentication_error
                .to_string()
                .contains("vault authentication failed"),
            "unexpected error: {authentication_error}"
        );
        let ciphertext_tampered_destination = root.path().join("ciphertext-tampered");
        fs::create_dir(&ciphertext_tampered_destination).expect("ciphertext destination");
        assert!(unpack_image(&image, &ciphertext_tampered_destination, &layout, &keys).is_err());
        assert!(fs::read_dir(&ciphertext_tampered_destination)
            .expect("read ciphertext destination")
            .next()
            .is_none());
    }
}
