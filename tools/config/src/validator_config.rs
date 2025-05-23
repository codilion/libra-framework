use crate::{
    make_yaml_public_fullnode::{make_private_vfn_yaml, VFN_FILENAME},
    make_yaml_validator,
};
use anyhow::{anyhow, bail, Context};
use dialoguer::{Confirm, Input};
use diem_crypto::x25519;
use diem_genesis::{config::HostAndPort, keys::PublicIdentity};
use diem_types::{chain_id::NamedChain, network_address::DnsName};
use libra_types::{
    core_types::{app_cfg::AppCfg, network_playlist::NetworkPlaylist},
    ol_progress::{self, OLProgress},
};
use libra_wallet::{utils::read_public_identity_file, validator_files::SetValidatorConfiguration};
use std::{
    path::{Path, PathBuf},
    str::FromStr,
};

// /// removes the TX signing key from the validator key files
// /// like private-identity.yaml
// pub async fn initialize_safer_validator(
//     home_path: Option<PathBuf>,
//     username: Option<&str>,
//     host: HostAndPort,
//     mnem: Option<String>,
//     keep_legacy_address: bool,
//     chain_name: Option<NamedChain>,
// ) -> anyhow::Result<PublicIdentity> {
//     let (.., _, pub_id, keys) =
//         libra_wallet::keys::refresh_validator_files(mnem, home_path.clone(), keep_legacy_address)?;
//     OLProgress::complete("initialized validator key files");

//     // TODO: set validator fullnode configs. Not NONE
//     let effective_username = username.unwrap_or("default_username"); // Use default if None
//     SetValidatorConfiguration::new(home_path.clone(), effective_username.to_owned(), host, None)
//         .set_config_files()?;
//     OLProgress::complete("saved validator registration files locally");

//     make_yaml_validator::save_validator_yaml(home_path.clone()).await?;
//     OLProgress::complete("saved validator node yaml file locally");

//     // TODO: nice to have
//     // also for convenience create a local user libra-cli-config.yaml file so the
//     // validator can make transactions against the localhost
//     let mut cfg = AppCfg::init_app_configs(
//         keys.child_0_owner.auth_key,
//         keys.child_0_owner.account,
//         home_path,
//         chain_name,
//         Some(NetworkPlaylist::localhost(chain_name)),
//     )?;

//     // offer the validator pledge on startup
//     let profile = cfg.get_profile_mut(None)?;
//     profile.maybe_offer_basic_pledge();
//     profile.maybe_offer_validator_pledge();

//     cfg.save_file().context(format!(
//         "could not initialize configs at {}",
//         cfg.workspace.node_home.to_str().unwrap()
//     ))?;
//     OLProgress::complete("saved a user libra-cli-config.yaml file locally");

//     Ok(pub_id)
// }

/// initializes a validator node's files
/// returns 0: the public identity, and 1: the Libra AppCfg
/// NOTE: this calls the save_val_files, which always removes
/// the transaction private key from the validator files.
pub async fn initialize_validator_files(
    home_path: Option<PathBuf>,
    username: Option<&str>,
    host: HostAndPort,
    mnem: Option<String>,
    keep_legacy_address: bool,
    chain_name: Option<NamedChain>,
) -> anyhow::Result<(PublicIdentity, AppCfg)> {
    let (account, authkey, pub_id) =
        libra_wallet::keys::refresh_validator_files(mnem, home_path.clone(), keep_legacy_address)?;
    OLProgress::complete("initialized validator key files");

    // TODO: set validator fullnode configs. Not NONE
    let effective_username = username.unwrap_or("default_username"); // Use default if None
    SetValidatorConfiguration::new(home_path.clone(), effective_username.to_owned(), host, None)
        .set_config_files()?;
    OLProgress::complete("saved validator registration files locally");

    make_yaml_validator::save_validator_yaml(home_path.clone()).await?;
    OLProgress::complete("saved validator node yaml file locally");

    // TODO: nice to have
    // also for convenience create a local user libra-cli-config.yaml file so the
    // validator can make transactions against the localhost
    let mut cfg = AppCfg::init_app_configs(
        authkey,
        account,
        home_path,
        chain_name,
        Some(NetworkPlaylist::localhost(chain_name)),
    )?;

    // offer the validator pledge on startup
    let profile = cfg.get_profile_mut(None)?;
    profile.maybe_offer_basic_pledge();
    profile.maybe_offer_validator_pledge();

    cfg.save_file().context(format!(
        "could not initialize configs at {}",
        cfg.workspace.node_home.to_str().unwrap()
    ))?;
    OLProgress::complete("saved a user libra-cli-config.yaml file locally");

    Ok((pub_id, cfg))
}

// Function to get the external IP address of the host
async fn get_ip() -> anyhow::Result<HostAndPort> {
    let res = reqwest::get("https://ipinfo.io/ip").await?;
    match res.text().await {
        Ok(ip_str) => HostAndPort::from_str(&format!("{}:6180", ip_str)),
        _ => bail!("can't get this host's external ip"),
    }
}

/// interact with user to get ip address
pub async fn what_host() -> Result<HostAndPort, anyhow::Error> {
    // get from external source since many cloud providers show different interfaces for `machine_ip`
    if let Ok(h) = get_ip().await {
        let txt = &format!(
            "Will you use this host, and this IP address {:?}, for your node?",
            h.host.to_string()
        );
        if Confirm::new().with_prompt(txt).interact().unwrap() {
            return Ok(h);
        }
    };

    let input: String = Input::new()
        .with_prompt("Enter the DNS or IP address, with port. Use validator: 6180, VFN: 6181, fullnode: 6182")
        .interact_text()
        .unwrap();
    let ip = input
        .parse::<HostAndPort>()
        .expect("Could not parse IP or DNS address");

    Ok(ip)
}

// Function to handle the validator dialogue with the user
pub async fn validator_dialogue(
    data_path: &Path,
    github_username: Option<&str>,
    chain_name: Option<NamedChain>,
) -> Result<(), anyhow::Error> {
    let to_init = Confirm::new()
        .with_prompt(format!(
            "Want to freshen configs at {} now?",
            data_path.display()
        ))
        .interact()?;
    if to_init {
        let host = what_host().await?;

        let keep_legacy_address = Confirm::new()
            .with_prompt(
                "Will you use a legacy V5 address in registration (32 characters or less)?",
            )
            .interact()?;

        let (pub_id, _) = initialize_validator_files(
            Some(data_path.to_path_buf()),
            github_username,
            host.clone(),
            None,
            keep_legacy_address,
            chain_name,
        )
        .await?;

        // now set up the vfn.yaml on the same host for convenience
        vfn_dialogue(
            data_path,
            Some(host.host),
            pub_id.validator_network_public_key,
        )
        .await?;
    }

    Ok(())
}

// Function to get the local validator full node ID
fn get_local_vfn_id(home: &Path) -> anyhow::Result<x25519::PublicKey> {
    let id = read_public_identity_file(&home.join("public-keys.yaml"))?;

    id.validator_network_public_key
        .context("no validator public key found in public-keys.yaml")
}

/// Handles the dialogue for setting up the validator full node (VFN) configuration
pub async fn vfn_dialogue(
    home: &Path,
    host: Option<DnsName>,
    net_pubkey: Option<x25519::PublicKey>,
) -> anyhow::Result<()> {
    let dns = match host {
        Some(d) => d,
        None => {
            println!("Let's get the network address of your VALIDATOR host");

            what_host().await?.host
        }
    };

    let pk = match net_pubkey {
        Some(r) => r,
        // maybe they already have the public-keys.yaml here
        None => get_local_vfn_id(home).map_err(|e| {
              anyhow!("ERROR: cannot make vfn.yaml, make sure you have the public-keys.yaml on this host before starting, message: {}", e)
        })?,
    };

    make_private_vfn_yaml(
        home,
        // NOTE: the VFN needs to identify the validator node, which uses the
        // same validator_network public ID
        pk, dns,
    )?;

    ol_progress::OLProgress::complete(&format!("SUCCESS: config saved to {}", VFN_FILENAME));

    println!("NOTE: on your VFN host you must place this vfn.yaml file in config directory before starting node.");

    Ok(())
}

#[tokio::test]
async fn test_validator_files_config() {
    use libra_types::global_config_dir;
    let alice_mnem = "talent sunset lizard pill fame nuclear spy noodle basket okay critic grow sleep legend hurry pitch blanket clerk impose rough degree sock insane purse".to_string();
    let h = HostAndPort::local(6180).unwrap();
    let test_path = global_config_dir().join("test_genesis");
    if test_path.exists() {
        std::fs::remove_dir_all(&test_path).unwrap();
    }

    initialize_validator_files(
        Some(test_path.clone()),
        Some("validator"),
        h,
        Some(alice_mnem),
        false,
        None,
    )
    .await
    .unwrap();

    std::fs::remove_dir_all(&test_path).unwrap();
}
