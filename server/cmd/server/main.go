// Apex Books sync server entrypoint.
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"time"

	"apexbooks/syncserver/internal/api"
	"apexbooks/syncserver/internal/store"
)

func main() {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		log.Fatal("DATABASE_URL is required")
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	st, err := store.Open(ctx, dbURL)
	if err != nil {
		log.Fatalf("store open failed: %v", err)
	}
	defer st.Close()

	auth, err := api.NewArgon2Auth()
	if err != nil {
		log.Fatalf("auth init failed: %v", err)
	}

	srv := &api.Server{Store: st, Auth: auth}
	addr := ":" + port
	log.Printf("apexbooks sync API listening on %s", addr)

	h := &http.Server{
		Addr:              addr,
		Handler:           srv.Routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Fatal(h.ListenAndServe())
}
