// Copyright © Aptos Foundation
// SPDX-License-Identifier: Apache-2.0

#![forbid(unsafe_code)]

use diem_framework::{
    docgen::DocgenOptions, BuildOptions, ReleaseBundle, ReleaseOptions, RELEASE_BUNDLE_EXTENSION,
};
use move_command_line_common::address::NumericalAddress;
use once_cell::sync::Lazy;
use std::{collections::BTreeMap, env, fmt::Display, path::PathBuf, str::FromStr};

use crate::BYTECODE_VERSION;

// ===============================================================================================
// Release Targets

// TODO: this one should be renamed or we should extend diem ReleaseTarget
/// Represents the available release targets. `Current` is in sync with the current client branch,
/// which is ensured by tests.
#[derive(clap::ValueEnum, Clone, Copy, Debug)]
pub enum ReleaseTarget {
    Head,
    Devnet,
    Testnet,
    Mainnet,
}

impl Display for ReleaseTarget {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let str = match self {
            ReleaseTarget::Head => "head",
            ReleaseTarget::Devnet => "devnet",
            ReleaseTarget::Testnet => "testnet",
            ReleaseTarget::Mainnet => "mainnet",
        };
        write!(f, "{}", str)
    }
}

impl FromStr for ReleaseTarget {
    type Err = &'static str;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "head" => Ok(ReleaseTarget::Head),
            "devnet" => Ok(ReleaseTarget::Devnet),
            "testnet" => Ok(ReleaseTarget::Testnet),
            "mainnet" => Ok(ReleaseTarget::Mainnet),
            _ => Err("Invalid target. Valid values are: head, devnet, testnet, mainnet"),
        }
    }
}

impl ReleaseTarget {
    /// Returns the package directories (relative to `framework`), in the order
    /// they need to be published, as well as an optional path to the file where
    /// rust bindings generated from the package should be stored.
    pub fn packages(self) -> Vec<(&'static str, Option<&'static str>)> {
        let result = vec![
            ("move-stdlib", None),
            ("vendor-stdlib", None),
            (
                "libra-framework",
                Some("cached-packages/src/libra_framework_sdk_builder.rs"),
            ),
        ];
        // Currently we don't have experimental packages only included in particular targets.
        result
    }

    /// Returns the file name under which this particular target's release buundle is stored.
    /// For example, for `Head` the file name will be `head.mrb`.
    pub fn file_name(self) -> String {
        format!("{}.{}", self, RELEASE_BUNDLE_EXTENSION)
    }

    /// Loads the release bundle for this particular target.
    pub fn load_bundle(&self) -> anyhow::Result<ReleaseBundle> {
        //////// 0L ////////
        let path = self.find_bundle_path()?;
        ReleaseBundle::read(path)
    }

    //////// 0L ////////
    /// In test and debug runs, find the local release path.
    pub fn find_bundle_path(&self) -> anyhow::Result<PathBuf> {
        let this_path = PathBuf::from_str(env!("CARGO_MANIFEST_DIR"))?;
        Ok(this_path.join("releases").join(self.file_name()))
    }
    /// Loads a bundle from .mrb file. Used for production cases.
    pub fn load_bundle_from_file(path: PathBuf) -> anyhow::Result<ReleaseBundle> {
        //////// 0L ////////
        // helper to return a bundle from file
        ReleaseBundle::read(path)
    }

    pub fn create_release_options(self, dev_mode: bool, out: Option<PathBuf>) -> ReleaseOptions {
        // Get the path to source. If we are running tests in cargo we
        // can assume cargo manifest dir.
        // Otherwise we assume the tool is being run in the source path

        let source_path = if let Ok(p) = env::var("CARGO_MANIFEST_DIR") {
            println!("using Cargo project path: {}", &p);
            PathBuf::from(p)
        } else {
            env::current_dir().expect("could not get local current_dir")
        };

        // let crate_dir = crate_dir.parent().unwrap().to_path_buf();
        let packages = self
            .packages()
            .into_iter()
            .map(|(path, binding_path)| {
                (
                    source_path.join(path),
                    binding_path.unwrap_or("").to_owned(),
                )
            })
            .collect::<Vec<_>>();
        ReleaseOptions {
            build_options: BuildOptions {
                dev: dev_mode,
                with_srcs: dev_mode,
                with_abis: true,
                with_source_maps: dev_mode,
                with_error_map: true,
                named_addresses: Default::default(),
                install_dir: None,
                with_docs: true,
                docgen_options: Some(DocgenOptions {
                    include_impl: true,
                    include_specs: true,
                    specs_inlined: false,
                    include_dep_diagram: false,
                    collapsed_sections: true,
                    landing_page_template: Some("doc_template/overview.md".to_string()),
                    references_file: Some("doc_template/references.md".to_string()),
                }),
                skip_fetch_latest_git_deps: true,
                bytecode_version: Some(BYTECODE_VERSION),
            },
            packages: packages.iter().map(|(path, _)| path.to_owned()).collect(),
            rust_bindings: packages
                .into_iter()
                .map(|(_, binding)| {
                    if !binding.is_empty() {
                        source_path.join(binding).display().to_string()
                    } else {
                        binding
                    }
                })
                .collect(),
            output: if let Some(path) = out {
                path
            } else {
                // Place in release directory //////// 0L ////////
                source_path.join("releases/head.mrb")
            },
        }
    }

    pub fn create_release(self, dev_mode: bool, out: Option<PathBuf>) -> anyhow::Result<()> {
        let options = self.create_release_options(dev_mode, out);
        #[cfg(unix)]
        {
            options.create_release()
        }
        #[cfg(windows)]
        {
            // Windows requires to set the stack because the package compiler puts too much on the
            // stack for the default size.  A quick internet search has shown the new thread with
            // a custom stack size is the easiest course of action.
            const STACK_SIZE: usize = 4 * 1024 * 1024;
            let child_thread = std::thread::Builder::new()
                .name("Framework-release".to_string())
                .stack_size(STACK_SIZE)
                .spawn(|| options.create_release())
                .expect("Expected to spawn release thread");
            child_thread
                .join()
                .expect("Expected to join release thread")
        }
    }
}

// ===============================================================================================
// Legacy Named Addresses

// Some older Move tests work directly on sources, skipping the package system. For those
// we define the relevant address aliases here.

static NAMED_ADDRESSES: Lazy<BTreeMap<String, NumericalAddress>> = Lazy::new(|| {
    let mut result = BTreeMap::new();
    let zero = NumericalAddress::parse_str("0x0").unwrap();
    let one = NumericalAddress::parse_str("0x1").unwrap();
    let three = NumericalAddress::parse_str("0x3").unwrap();
    let four = NumericalAddress::parse_str("0x4").unwrap();
    let resources = NumericalAddress::parse_str("0xA550C18").unwrap();
    result.insert("std".to_owned(), one);
    result.insert("diem_std".to_owned(), one);
    result.insert("diem_framework".to_owned(), one);
    result.insert("diem_token".to_owned(), three);
    result.insert("diem_token_objects".to_owned(), four);
    result.insert("core_resources".to_owned(), resources);
    result.insert("vm_reserved".to_owned(), zero);
    result.insert("ol_framework".to_owned(), one); /////// 0L /////////
    result
});

pub fn named_addresses() -> &'static BTreeMap<String, NumericalAddress> {
    &NAMED_ADDRESSES
}
