package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Secret   string `yaml:"secret"`
	Port     uint   `yaml:"port"`
	DataFile string `yaml:"data_file"`
}

func main() {
	configPath := flag.String("config", "config.yaml", "path to config file")
	flag.Parse()

	raw, err := os.ReadFile(*configPath)
	if err != nil {
		log.Fatal(err)
	}
	var cfg Config
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		log.Fatal(err)
	}
	if cfg.DataFile == "" {
		cfg.DataFile = "seshat-data.json"
	}

	store, err := NewStore(cfg.DataFile)
	if err != nil {
		log.Fatalf("load store: %v", err)
	}
	srv := &Server{store: store, secret: cfg.Secret}

	addr := fmt.Sprintf(":%d", cfg.Port)
	log.Printf("seshat server listening on %s, data=%s", addr, cfg.DataFile)
	if err := http.ListenAndServe(addr, srv.mux()); err != nil {
		log.Fatal(err)
	}
}
