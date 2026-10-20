//! Pick a whisper.cpp model and backend from the hardware.

#[derive(Debug, Clone, PartialEq)]
pub struct Hardware {
    pub ram_gb: u64,
    pub cores: usize,
    pub cuda: bool,
    pub vulkan: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Choice {
    /// ggml model name, downloaded as `ggml-<model>.bin`.
    pub model: &'static str,
    pub backend: &'static str,
}

pub fn choose(hw: &Hardware) -> Choice {
    // A GPU only helps if there is RAM to load large-v3-turbo (~1.6 GB) next to the desktop.
    if hw.ram_gb >= 8 && hw.cuda {
        return Choice { model: "large-v3-turbo", backend: "cuda" };
    }
    if hw.ram_gb >= 8 && hw.vulkan {
        return Choice { model: "large-v3-turbo", backend: "vulkan" };
    }
    // ponytail: RAM/core thresholds are guesses, tune them from real latency numbers.
    let model = match (hw.ram_gb, hw.cores) {
        (r, c) if r >= 16 && c >= 8 => "small",
        (r, _) if r >= 8 => "base",
        _ => "tiny",
    };
    Choice { model, backend: "cpu" }
}

/// Read the hardware of this machine.
pub fn detect() -> Hardware {
    let kb = std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|s| s.lines().find(|l| l.starts_with("MemTotal:"))
            .and_then(|l| l.split_whitespace().nth(1)?.parse::<u64>().ok()))
        .unwrap_or(0);
    let vulkan = std::fs::read_dir("/usr/share/vulkan/icd.d")
        .map(|d| d.count() > 0)
        .unwrap_or(false);
    Hardware {
        // MemTotal is a bit under the installed size, so round up.
        ram_gb: kb.div_ceil(1024 * 1024),
        cores: std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1),
        cuda: std::path::Path::new("/dev/nvidia0").exists(),
        vulkan,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hw(ram_gb: u64, cores: usize, cuda: bool, vulkan: bool) -> Hardware {
        Hardware { ram_gb, cores, cuda, vulkan }
    }

    #[test]
    fn cuda_beats_vulkan() {
        assert_eq!(choose(&hw(16, 8, true, true)), Choice { model: "large-v3-turbo", backend: "cuda" });
        assert_eq!(choose(&hw(16, 8, false, true)), Choice { model: "large-v3-turbo", backend: "vulkan" });
    }

    #[test]
    fn gpu_with_too_little_ram_falls_back_to_cpu() {
        assert_eq!(choose(&hw(7, 4, true, true)), Choice { model: "tiny", backend: "cpu" });
    }

    #[test]
    fn cpu_tiers_follow_ram_and_cores() {
        assert_eq!(choose(&hw(16, 8, false, false)).model, "small");
        assert_eq!(choose(&hw(16, 7, false, false)).model, "base");
        assert_eq!(choose(&hw(8, 2, false, false)).model, "base");
        assert_eq!(choose(&hw(7, 16, false, false)).model, "tiny");
    }
}
