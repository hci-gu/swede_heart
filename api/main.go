package main

import (
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"

	"path/filepath"

	_ "app/migrations"

	"github.com/google/uuid"
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
				Consent    bool   `json:"consent"`
				EventDate  string `json:"eventDate"`
			}{}
			if err := c.Bind(&data); err != nil {
				return apis.NewBadRequestError("Failed to read request data", err)
			}
			log.Printf("Request body: %v", data)

			user, _, err := findOrCreateUser(app, data.PersonalId, data.EventDate)
			if err != nil {
				return echo.NewHTTPError(http.StatusInternalServerError, "Failed to handle user")
			}

			collection, err := app.Dao().FindCollectionByNameOrId("consent")
			if err != nil {
				return echo.NewHTTPError(http.StatusInternalServerError, "Failed to find collection")
			}

			record := models.NewRecord(collection)
			record.Set("user", user.Id)
			record.Set("consented", data.Consent)
			app.Dao().SaveRecord(record)

			return c.JSON(http.StatusOK, user)
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

			// On first chunk, clear any existing data to prevent duplicates on retry
			if reqBody.ChunkIndex == 0 {
				if err := clearUserData(app, personalId); err != nil {
					log.Println("Error clearing existing data: ", err)
					return echo.NewHTTPError(http.StatusInternalServerError, "Failed to clear existing data")
				}
			}

			// Create a folder path for the user based on the PersonalId
			userFolder := filepath.Join(STORAGE_PATH, personalId)
			err := os.MkdirAll(userFolder, os.ModePerm) // MkdirAll creates the directory if it doesn't exist
			if err != nil {
				log.Println("Error: ", err)
				return err
			}

			// Use the current timestamp for the file name
			timestamp := time.Now()
			fileName := fmt.Sprintf("%s.json.gz", timestamp.Format("2006-01-02_15:04:05.000"))

			// Full file path within the user's folder
			filePath := filepath.Join(userFolder, fileName)
			err = writeCompressedFile(filePath, reqBody.Data)
			if err != nil {
				log.Println("Error: ", err)
				return err
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
				"message":  "Data saved successfully",
				"filePath": filePath,
			})
		})

		e.Router.GET("/data/:personalId", requireApiKey(func(c echo.Context) error {
			personalId, err := sanitizePersonalId(c.PathParam("personalId"))
			if err != nil {
				return echo.NewHTTPError(http.StatusBadRequest, "Invalid personalId")
			}

			// Construct the directory path based on the personalId
			userFolder := filepath.Join(STORAGE_PATH, personalId)

			// Open the directory and list all files
			files, err := os.ReadDir(userFolder)
			if err != nil {
				return err
			}

			// Slice to hold all concatenated data
			var allData []DataItem

			// Loop through each file in the directory
			for _, file := range files {
				// Ensure we're only processing .gz files
				if filepath.Ext(file.Name()) == ".gz" {
					// Construct the full file path
					filePath := filepath.Join(userFolder, file.Name())

					// Read and decompress the file (which contains an array of DataItem)
					dataItems, err := readCompressedFile(filePath)
					if err != nil {
						return err
					}

					// Append the data items to the allData slice
					allData = append(allData, dataItems...)
				}
			}

			// Return the concatenated array of data items
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

func findOrCreateUser(app *pocketbase.PocketBase, personalId, eventDate string) (*models.Record, string, error) {
	user, _ := getUserForPersonalId(app, personalId)

	if user != nil {
		return user, "", nil
	}

	collection, err := app.Dao().FindCollectionByNameOrId("users")
	if err != nil {
		return nil, "", err
	}

	record := models.NewRecord(collection)
	record.Set("username", personalId)
	record.Set("event_date", eventDate)
	uuid, _ := uuid.NewRandom()
	password := uuid.String()
	record.SetPassword(password)

	log.Println(record.TokenKey())

	if err := app.Dao().SaveRecord(record); err != nil {
		log.Println(err)
		return nil, "", err
	}

	return record, password, nil
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
