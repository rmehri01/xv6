Module["arguments"] = [
  "-accel",
  "tcg,tb-size=500",
  "-smp",
  "1",

  //Use the following to enable MTTCG
  // "-accel",
  // "tcg,tb-size=500,thread=multi",
  // "-smp",
  // "4,sockets=4",

  "-machine",
  "virt",
  "-bios",
  "none",
  "-m",
  "128M",
  "-cpu",
  "rv64",
  "-nographic",
  "-global",
  "virtio-mmio.force-legacy=false",
  "-drive",
  "file=/pack/fs.img,if=none,format=raw,id=x0",
  "-device",
  "virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0",
  "-kernel",
  "/pack/kernel",
];
Module["locateFile"] = function (path) {
  return "/xv6/" + path;
};
Module["mainScriptUrlOrBlob"] = "/xv6/out.js";
