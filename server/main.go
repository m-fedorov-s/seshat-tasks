package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"

	"encoding/json"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Secret string `yaml:"secret"`
	Port   uint   `yaml:"port"`
}

type Task struct {
	Title    string `json:"title"`
	Priority uint8  `json:"priority"`
}

type State struct {
	Tasks   []Task
	Version uint64
}

type GetHandler struct {
	secret string
	state  *State
}

func (h *GetHandler) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	if req.Header.Get("Authorization") != h.secret {
		http.Error(w, "Acces denied", http.StatusForbidden)
		return
	}
	enc := json.NewEncoder(w)
	err := enc.Encode(h.state.Tasks)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

type AddHandler struct {
	secret string
	state  *State
}

func (h *AddHandler) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	if req.Header.Get("Authorization") != h.secret {
		http.Error(w, "Acces denied", http.StatusForbidden)
		return
	}
	dec := json.NewDecoder(req.Body)
	var task Task
	err := dec.Decode(&task)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	h.state.Tasks = append(h.state.Tasks, task)
}

type DeleteHandler struct {
	secret string
	state  *State
}

func (h *DeleteHandler) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	if req.Header.Get("Authorization") != h.secret {
		http.Error(w, "Acces denied", http.StatusForbidden)
		return
	}
	dec := json.NewDecoder(req.Body)
	var task Task
	err := dec.Decode(&task)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
	// Filtering
	n := 0
	for _, t := range h.state.Tasks {
		if t.Title != task.Title {
			h.state.Tasks[n] = t
			n++
		}
	}
	h.state.Tasks = h.state.Tasks[:n]
}

func main() {
	fmt.Println("vim-go")
	configPathPtr := flag.String("config", "config.yaml", "Path to config file")
	flag.Parse()

	configBytes, err := os.ReadFile(*configPathPtr)
	if err != nil {
		log.Fatal(err)
	}

	config := Config{}
	err = yaml.Unmarshal(configBytes, &config)
	if err != nil {
		log.Fatal(err)
	}

	state := State{
		Version: 0,
		Tasks:   []Task{},
	}

	get_handler := &GetHandler{
		state:  &state,
		secret: config.Secret,
	}

	add_handler := &AddHandler{
		state:  &state,
		secret: config.Secret,
	}

	delete_handler := &DeleteHandler{
		state:  &state,
		secret: config.Secret,
	}

	http.Handle("/api/tasks/get", get_handler)
	http.Handle("/api/tasks/add", add_handler)
	http.Handle("/api/tasks/delete", delete_handler)

	err = http.ListenAndServe(fmt.Sprintf(":%v", config.Port), nil)
	if err != nil {
		log.Fatal(err)
	}

}
