package main

import (
	"compress/gzip"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"path/filepath"

	_ "app/migrations"

	"github.com/labstack/echo/v5"
	"github.com/labstack/echo/v5/middleware"
	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/models"
	"github.com/pocketbase/pocketbase/plugins/migratecmd"
)

// const STORAGE_PATH = "./storage"
const STORAGE_PATH = "/pb/pb_data/raw"
const CERT_PATH = "/pb/cert"
const uploadStateTimeout = 30 * time.Minute
const uploadsDirectoryName = "_uploads"
const uploadStateFileName = ".upload_state.json"

var uploadLocks sync.Map

func requireApiKey(next echo.HandlerFunc) echo.HandlerFunc {
	return func(c echo.Context) error {
		key := os.Getenv("API_KEY")
		if key == "" {
			log.Println("WARNING: API_KEY environment variable is not set")
			return echo.NewHTTPError(http.StatusInternalServerError, "Server misconfigured")
		}

		provided := c.Request().Header.Get("X-API-Key")
		if provided == "" || provided != key {
			return echo.NewHTTPError(http.StatusUnauthorized, "Invalid or missing API key")
		}

		return next(c)
	}
}

var personalIdRegex = regexp.MustCompile(`^[a-zA-Z0-9\-]+$`)

func sanitizePersonalId(id string) (string, error) {
	if id == "" || !personalIdRegex.MatchString(id) {
		return "", fmt.Errorf("invalid personalId: %q", id)
	}
	return id, nil
}

type Value struct {
	NumericValue string `json:"numericValue"`
}

type DataItem struct {
	Value        Value  `json:"value"`
	DataType     string `json:"data_type"`
	Unit         string `json:"unit"`
	DateFrom     string `json:"date_from"`
	DateTo       string `json:"date_to"`
	PlatformType string `json:"platform_type"`
	DeviceId     string `json:"device_id"`
	SourceId     string `json:"source_id"`
	SourceName   string `json:"source_name"`
}

type UploadState struct {
	SessionID     string    `json:"sessionId"`
	ExpectedChunk int       `json:"expectedChunk"`
	StartedAt     time.Time `json:"startedAt"`
	UpdatedAt     time.Time `json:"updatedAt"`
}

func getUploadLock(personalId string) *sync.Mutex {
	lock, _ := uploadLocks.LoadOrStore(personalId, &sync.Mutex{})
	return lock.(*sync.Mutex)
}

func userFolderPath(personalId string) string {
	return filepath.Join(STORAGE_PATH, personalId)
}

func uploadsRootPath(personalId string) string {
	return filepath.Join(userFolderPath(personalId), uploadsDirectoryName)
}

func uploadSessionPath(personalId, sessionID string) string {
	return filepath.Join(uploadsRootPath(personalId), sessionID)
}

func uploadStatePath(personalId string) string {
	return filepath.Join(userFolderPath(personalId), uploadStateFileName)
}

func chunkFilePath(personalId, sessionID string, chunkIndex int) string {
	return filepath.Join(uploadSessionPath(personalId, sessionID), fmt.Sprintf("chunk-%05d.json.gz", chunkIndex))
}

func chunkHashPath(personalId, sessionID string, chunkIndex int) string {
	return filepath.Join(uploadSessionPath(personalId, sessionID), fmt.Sprintf("chunk-%05d.sha256", chunkIndex))
}

func newSessionID(now time.Time) (string, error) {
	token := make([]byte, 6)
	if _, err := rand.Read(token); err != nil {
		return "", err
	}
	return fmt.Sprintf("%s-%s", now.UTC().Format("20060102T150405.000000000Z"), hex.EncodeToString(token)), nil
}

func hashDataItems(data []DataItem) (string, error) {
	payload, err := json.Marshal(data)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(payload)
	return hex.EncodeToString(sum[:]), nil
}

func loadUploadState(personalId string) (*UploadState, error) {
	raw, err := os.ReadFile(uploadStatePath(personalId))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	var state UploadState
	if err := json.Unmarshal(raw, &state); err != nil {
		return nil, err
	}
	if state.SessionID == "" {
		return nil, nil
	}

	return &state, nil
}

func saveUploadState(personalId string, state *UploadState) error {
	stateDir := userFolderPath(personalId)
	if err := os.MkdirAll(stateDir, os.ModePerm); err != nil {
		return err
	}

	raw, err := json.Marshal(state)
	if err != nil {
		return err
	}

	return os.WriteFile(uploadStatePath(personalId), raw, 0o600)
}

func isUploadStateExpired(state *UploadState, now time.Time) bool {
	if state == nil {
		return true
	}
	return now.Sub(state.UpdatedAt) > uploadStateTimeout
}

func createNewUploadState(personalId string, now time.Time) (*UploadState, error) {
	sessionID, err := newSessionID(now)
	if err != nil {
		return nil, err
	}

	sessionDir := uploadSessionPath(personalId, sessionID)
	if err := os.MkdirAll(sessionDir, os.ModePerm); err != nil {
		return nil, err
	}

	state := &UploadState{
		SessionID:     sessionID,
		ExpectedChunk: 0,
		StartedAt:     now,
		UpdatedAt:     now,
	}
	if err := saveUploadState(personalId, state); err != nil {
		return nil, err
	}

	return state, nil
}

func isDuplicateChunk(personalId string, state *UploadState, chunkIndex int, incomingHash string) (bool, error) {
	existingHashBytes, err := os.ReadFile(chunkHashPath(personalId, state.SessionID, chunkIndex))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}

	existingHash := strings.TrimSpace(string(existingHashBytes))
	return existingHash == incomingHash, nil
}

func saveChunkHash(personalId string, state *UploadState, chunkIndex int, hash string) error {
	return os.WriteFile(chunkHashPath(personalId, state.SessionID, chunkIndex), []byte(hash), 0o600)
}

func listSessionDirectories(personalId string) ([]string, error) {
	entries, err := os.ReadDir(uploadsRootPath(personalId))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	dirs := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			dirs = append(dirs, entry.Name())
		}
	}
	sort.Strings(dirs)

	return dirs, nil
}

func readDataFromSession(personalId, sessionID string) ([]DataItem, error) {
	sessionDir := uploadSessionPath(personalId, sessionID)
	files, err := os.ReadDir(sessionDir)
	if err != nil {
		return nil, err
	}

	chunkFiles := make([]string, 0, len(files))
	for _, file := range files {
		name := file.Name()
		if !file.IsDir() && strings.HasPrefix(name, "chunk-") && strings.HasSuffix(name, ".json.gz") {
			chunkFiles = append(chunkFiles, name)
		}
	}
	sort.Strings(chunkFiles)

	var allData []DataItem
	for _, chunkFile := range chunkFiles {
		filePath := filepath.Join(sessionDir, chunkFile)
		dataItems, err := readCompressedFile(filePath)
		if err != nil {
			return nil, err
		}
		allData = append(allData, dataItems...)
	}

	return allData, nil
}

func readLegacyData(userFolder string) ([]DataItem, error) {
	files, err := os.ReadDir(userFolder)
	if err != nil {
		return nil, err
	}

	gzipFiles := make([]string, 0, len(files))
	for _, file := range files {
		if !file.IsDir() && filepath.Ext(file.Name()) == ".gz" {
			gzipFiles = append(gzipFiles, file.Name())
		}
	}
	sort.Strings(gzipFiles)

	var allData []DataItem
	for _, gzipFile := range gzipFiles {
		filePath := filepath.Join(userFolder, gzipFile)
		dataItems, err := readCompressedFile(filePath)
		if err != nil {
			return nil, err
		}
		allData = append(allData, dataItems...)
	}

	return allData, nil
}

// Function to parse date strings and return the earliest and latest dates
func getEarliestAndLatestDates(data []DataItem) (earliest string, latest string, err error) {
	if len(data) == 0 {
		return "", "", fmt.Errorf("no data points provided")
	}

	// Initialize earliest and latest dates with the first item's dates
	earliest = data[0].DateFrom
	latest = data[0].DateTo

	// Iterate through the data to find the actual earliest and latest dates
	for _, item := range data {
		if strings.Compare(item.DateFrom, earliest) < 0 {
			earliest = item.DateFrom
		}
		if strings.Compare(item.DateTo, latest) > 0 {
			latest = item.DateTo
		}
	}

	return earliest, latest, nil
}

// Write compressed data to a file
func writeCompressedFile(filePath string, data []DataItem) error {
	// Convert the []DataItem array to JSON
	jsonData, err := json.Marshal(data)
	if err != nil {
		return err
	}

	// Create the file for writing compressed data
	file, err := os.Create(filePath)
	if err != nil {
		return err
	}
	defer file.Close()

	// Create a gzip writer
	gzipWriter := gzip.NewWriter(file)
	defer gzipWriter.Close()

	// Write compressed data
	_, err = gzipWriter.Write(jsonData)
	if err != nil {
		return err
	}

	return nil
}

// Read and decompress the file
func readCompressedFile(filePath string) ([]DataItem, error) {
	// Open the compressed file
	file, err := os.Open(filePath)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	// Create a gzip reader
	gzipReader, err := gzip.NewReader(file)
	if err != nil {
		return nil, err
	}
	defer gzipReader.Close()

	// Read and decompress the data
	decompressedData, err := io.ReadAll(gzipReader)
	if err != nil {
		return nil, err
	}

	// Unmarshal the decompressed data into []DataItem
	var dataItems []DataItem
	if err := json.Unmarshal(decompressedData, &dataItems); err != nil {
		return nil, err
	}

	return dataItems, nil
}

func main() {
	app := pocketbase.New()

	isGoRun := strings.HasPrefix(os.Args[0], os.TempDir())

	migratecmd.MustRegister(app, app.RootCmd, migratecmd.Config{
		Automigrate: isGoRun,
	})

	app.OnBeforeServe().Add(func(e *core.ServeEvent) error {

		e.Router.Use(middleware.Decompress())
		e.Router.Use(middleware.BodyLimit(200 * 1024 * 1024))

		e.Router.GET("/test", func(c echo.Context) error {
			return c.String(http.StatusOK, "Test endpoint")
		})

		e.Router.POST("/users", func(c echo.Context) error {
			data := struct {
				PersonalId string `json:"personalId"`
				Password   string `json:"password"`
				Consent    bool   `json:"consent"`
			}{}
			if err := c.Bind(&data); err != nil {
				return apis.NewBadRequestError("Failed to read request data", err)
			}

			if data.Password == "" {
				return echo.NewHTTPError(http.StatusBadRequest, "Password is required")
			}

			personalId, err := sanitizePersonalId(data.PersonalId)
			if err != nil {
				return echo.NewHTTPError(http.StatusBadRequest, "Invalid personalId")
			}

			user, err := findOrCreateUser(app, personalId, data.Password)
			if err != nil {
				return echo.NewHTTPError(http.StatusInternalServerError, "Failed to handle user")
			}

			// Set consent on user record
			user.Set("consent", data.Consent)
			if err := app.Dao().SaveRecord(user); err != nil {
				log.Println("Error saving consent on user:", err)
			}

			return c.JSON(http.StatusOK, map[string]interface{}{
				"id": user.Id,
			})
		})

		e.Router.POST("/:id/form", func(c echo.Context) error {
			id := c.PathParam("id")
			data := struct {
				Name    string      `json:"name"`
				Answers interface{} `json:"answers"`
			}{}

			if err := c.Bind(&data); err != nil {
				return apis.NewBadRequestError("Failed to read request data", err)
			}

			user, err := getUserForPersonalId(app, id)
			if err != nil {
				return echo.NewHTTPError(http.StatusNotFound, "User not found")
			}

			questionnaire, err := app.Dao().FindFirstRecordByData("questionnaires", "name", data.Name)

			if questionnaire == nil || err != nil {
				return echo.NewHTTPError(http.StatusNotFound, "Questionnaire not found")
			}

			collection, err := app.Dao().FindCollectionByNameOrId("answers")
			if err != nil {
				return echo.NewHTTPError(http.StatusInternalServerError, "Failed to find collection")
			}

			record := models.NewRecord(collection)
			record.Set("user", user.Id)
			record.Set("questionnaire", questionnaire.Id)
			record.Set("answers", data.Answers)
			app.Dao().SaveRecord(record)

			return nil
		})

		e.Router.POST("/info", func(c echo.Context) error {
			reqBody := struct {
				PersonalId string                 `json:"personalId"`
				Data       map[string]interface{} `json:"data"`
			}{}
			if err := c.Bind(&reqBody); err != nil {
				log.Println("Error: ", err)
				return echo.NewHTTPError(http.StatusBadRequest, "Invalid request body")
			}

			user, err := getUserForPersonalId(app, reqBody.PersonalId)
			if err != nil {
				return echo.NewHTTPError(http.StatusNotFound, "User not found")
			}

			collection, err := app.Dao().FindCollectionByNameOrId("info")
			if err != nil {
				return echo.NewHTTPError(http.StatusInternalServerError, "Failed to find collection")
			}

			record := models.NewRecord(collection)
			record.Set("user", user.Id)
			record.Set("data", reqBody.Data)
			app.Dao().SaveRecord(record)

			return nil
		})

		e.Router.POST("/data", func(c echo.Context) error {
			println("POST /data")
			reqBody := struct {
				PersonalId string     `json:"personalId"`
				ChunkIndex int        `json:"chunkIndex"`
				Data       []DataItem `json:"data"`
			}{}

			if err := c.Bind(&reqBody); err != nil {
				log.Println("Error: ", err)
				return echo.NewHTTPError(http.StatusBadRequest, "Invalid request body")
			}

			personalId, err := sanitizePersonalId(reqBody.PersonalId)
			if err != nil {
				return echo.NewHTTPError(http.StatusBadRequest, "Invalid personalId")
			}

			if reqBody.ChunkIndex < 0 {
				return echo.NewHTTPError(http.StatusBadRequest, "Invalid chunkIndex")
			}

			if len(reqBody.Data) == 0 {
				return echo.NewHTTPError(http.StatusBadRequest, "No data points provided")
			}

			dataHash, err := hashDataItems(reqBody.Data)
			if err != nil {
				log.Println("Error hashing data: ", err)
				return echo.NewHTTPError(http.StatusInternalServerError, "Failed to process upload")
			}

			now := time.Now().UTC()
			lock := getUploadLock(personalId)
			lock.Lock()
			defer lock.Unlock()

			state, err := loadUploadState(personalId)
			if err != nil {
				log.Println("Error loading upload state: ", err)
				return echo.NewHTTPError(http.StatusInternalServerError, "Failed to read upload state")
			}

			switch {
			case reqBody.ChunkIndex == 0:
				if state == nil || isUploadStateExpired(state, now) {
					state, err = createNewUploadState(personalId, now)
					if err != nil {
						log.Println("Error creating upload state: ", err)
						return echo.NewHTTPError(http.StatusInternalServerError, "Failed to start upload")
					}
				} else if state.ExpectedChunk > 0 {
					duplicateFirstChunk, err := isDuplicateChunk(personalId, state, 0, dataHash)
					if err != nil {
						log.Println("Error checking duplicate first chunk: ", err)
						return echo.NewHTTPError(http.StatusInternalServerError, "Failed to process upload")
					}
					if !duplicateFirstChunk {
						state, err = createNewUploadState(personalId, now)
						if err != nil {
							log.Println("Error rotating upload state: ", err)
							return echo.NewHTTPError(http.StatusInternalServerError, "Failed to restart upload")
						}
					}
				}
			case state == nil || isUploadStateExpired(state, now):
				return echo.NewHTTPError(http.StatusConflict, "No active upload session. Restart from chunk 0.")
			}

			if reqBody.ChunkIndex > state.ExpectedChunk {
				return echo.NewHTTPError(http.StatusConflict, fmt.Sprintf("Out-of-order chunk. Expected chunk %d.", state.ExpectedChunk))
			}

			if reqBody.ChunkIndex < state.ExpectedChunk {
				isDuplicate, err := isDuplicateChunk(personalId, state, reqBody.ChunkIndex, dataHash)
				if err != nil {
					log.Println("Error checking duplicate chunk: ", err)
					return echo.NewHTTPError(http.StatusInternalServerError, "Failed to process upload")
				}
				if !isDuplicate {
					return echo.NewHTTPError(http.StatusConflict, "Chunk already received with different content.")
				}
				filePath := chunkFilePath(personalId, state.SessionID, reqBody.ChunkIndex)
				return c.JSON(http.StatusOK, map[string]interface{}{
					"message":    "Chunk already received",
					"filePath":   filePath,
					"sessionId":  state.SessionID,
					"chunkIndex": reqBody.ChunkIndex,
				})
			}

			filePath := chunkFilePath(personalId, state.SessionID, reqBody.ChunkIndex)
			if err := os.MkdirAll(filepath.Dir(filePath), os.ModePerm); err != nil {
				log.Println("Error creating session directory: ", err)
				return err
			}

			timestamp := now
			if err := writeCompressedFile(filePath, reqBody.Data); err != nil {
				log.Println("Error: ", err)
				return err
			}
			if err := saveChunkHash(personalId, state, reqBody.ChunkIndex, dataHash); err != nil {
				log.Println("Error saving chunk hash: ", err)
				return echo.NewHTTPError(http.StatusInternalServerError, "Failed to persist chunk metadata")
			}

			state.ExpectedChunk++
			state.UpdatedAt = now
			if err := saveUploadState(personalId, state); err != nil {
				log.Println("Error saving upload state: ", err)
				return echo.NewHTTPError(http.StatusInternalServerError, "Failed to persist upload state")
			}

			// Extract the earliest and latest dates from the data
			datafrom, dataTo, err := getEarliestAndLatestDates(reqBody.Data)
			if err != nil {
				log.Println("Error: ", err)
				return err
			}

			collection, err := app.Dao().FindCollectionByNameOrId("dataUploads")
			if err != nil {
				log.Println("Error: ", err)
				return err
			}

			user, err := getUserForPersonalId(app, personalId)
			if err != nil {
				log.Println("Error: ", err)
				return err
			}

			record := models.NewRecord(collection)
			record.Set("user", user.Id)
			record.Set("filePath", filePath)
			record.Set("timestamp", timestamp)
			record.Set("dataFrom", datafrom)
			record.Set("dataTo", dataTo)

			if err := app.Dao().SaveRecord(record); err != nil {
				log.Println("Error: ", err)
				return err
			}

			// Return success with metadata
			return c.JSON(http.StatusOK, map[string]interface{}{
				"message":    "Data saved successfully",
				"filePath":   filePath,
				"sessionId":  state.SessionID,
				"chunkIndex": reqBody.ChunkIndex,
			})
		})

		e.Router.GET("/data/:personalId", requireApiKey(func(c echo.Context) error {
			personalId, err := sanitizePersonalId(c.PathParam("personalId"))
			if err != nil {
				return echo.NewHTTPError(http.StatusBadRequest, "Invalid personalId")
			}

			lock := getUploadLock(personalId)
			lock.Lock()
			defer lock.Unlock()

			var allData []DataItem
			sessionDirs, err := listSessionDirectories(personalId)
			if err != nil {
				return err
			}
			for i := len(sessionDirs) - 1; i >= 0; i-- {
				allData, err = readDataFromSession(personalId, sessionDirs[i])
				if err != nil {
					return err
				}
				if len(allData) > 0 {
					return c.JSON(http.StatusOK, allData)
				}
			}

			// Fallback for legacy data written directly under user folder
			userFolder := userFolderPath(personalId)
			allData, err = readLegacyData(userFolder)
			if err != nil {
				return err
			}
			return c.JSON(http.StatusOK, allData)
		}))

		return nil
	})

	if err := app.Start(); err != nil {
		log.Fatal(err)
	}
}

func getUserForPersonalId(app *pocketbase.PocketBase, personalId string) (*models.Record, error) {
	return app.Dao().FindFirstRecordByData("users", "username", personalId)
}

func findOrCreateUser(app *pocketbase.PocketBase, personalId, password string) (*models.Record, error) {
	user, _ := getUserForPersonalId(app, personalId)

	if user != nil {
		// Returning user: keep existing password to avoid expensive hash rewrites on every request.
		return user, nil
	}

	collection, err := app.Dao().FindCollectionByNameOrId("users")
	if err != nil {
		return nil, err
	}

	record := models.NewRecord(collection)
	record.Set("username", personalId)
	record.SetPassword(password)

	if err := app.Dao().SaveRecord(record); err != nil {
		log.Println(err)
		return nil, err
	}

	return record, nil
}

func clearUserData(app *pocketbase.PocketBase, personalId string) error {
	// personalId should already be sanitized by the caller, but verify
	if _, err := sanitizePersonalId(personalId); err != nil {
		return err
	}
	userFolder := filepath.Join(STORAGE_PATH, personalId)

	// Remove existing data files
	if err := os.RemoveAll(userFolder); err != nil && !os.IsNotExist(err) {
		return err
	}

	// Remove existing dataUploads records for this user
	user, err := getUserForPersonalId(app, personalId)
	if err != nil {
		return nil // no user means no records to clean
	}

	records, err := app.Dao().FindRecordsByFilter("dataUploads", "user = {:userId}", "", 0, 0, map[string]any{"userId": user.Id})
	if err != nil {
		return nil // no records to clean
	}

	for _, record := range records {
		if err := app.Dao().DeleteRecord(record); err != nil {
			log.Printf("Warning: failed to delete dataUpload record %s: %v", record.Id, err)
		}
	}

	return nil
}
