# gentoo_on_nas
patches and tools to run gentoo on readynas

## notes
If you have several USB devices connected before power on, the linux kernel may not able to finish USB hub probe within 5 seconds (the kernel default). In this case, add parameter `usbcore.initial_descriptor_timeout=10000` to kernel boot options.
