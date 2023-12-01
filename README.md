(ArchLinux only)

This script verifies whether any of the outdated packages (whose names show up when you run "pacman -Syu") have open issues in Arch GitLab issue tracker. It helps making decision whether you want to hold off updating certain packages if issues are found.

SYNAPSIS

    pacbug [--sync]

OPTIONS

    --sync
        Optional. Run "sudo pacman -Sy" to update package pacman database
        prior to checking against GitLab issue-tacker. This can be done manually before running "pacbug".

Sample output:

    \[boss@host\]$ pacbug --sync
    \[sudo\] password for boss:
    :: Synchronizing package databases...
     core                     131.1 KiB   835 KiB/s 00:00 [########################################################] 100%
     extra                      8.2 MiB  20.7 MiB/s 00:00 [########################################################] 100%
     multilib is up to date
    Upgradable package count: 48
    Ignoring issues created prior to: 2023-11-10 16:02:35
    GitLab issue count: 27
    pipewire : 2023-11-26 11:30:19, Low-latency audio/video router and processor, ISSUES
        Installing pipewire-pulse result in offering deprecated pipewire-media-session is getting installed by default
        https://gitlab.archlinux.org/archlinux/packaging/packages/pipewire/-/issues/2
    linux : 2023-11-28 19:37:40, The Linux kernel and modules, ISSUES
        ntfs3 module flushes changes to files only on unmount
        https://gitlab.archlinux.org/archlinux/packaging/packages/linux/-/issues/6
    WARNING: Upgradable package issue count: 2
