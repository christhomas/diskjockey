package disktypes

import (
	"fmt"
	"io"
	"strings"

	"github.com/christhomas/diskjockey/diskjockey-backend/models"
	"github.com/christhomas/diskjockey/diskjockey-backend/types"
	dropbox "github.com/dropbox/dropbox-sdk-go-unofficial/v6/dropbox"
	files "github.com/dropbox/dropbox-sdk-go-unofficial/v6/dropbox/files"
)

// DropboxDiskType implements DiskType for Dropbox

type DropboxDiskType struct{}

type DropboxBackend struct {
	mount  *models.Mount
	client files.Client
}

func (DropboxDiskType) New(mount *models.Mount) (types.Backend, error) {
	b := &DropboxBackend{
		mount: mount,
	}

	if err := b.connect(); err != nil {
		return nil, err
	}

	return b, nil
}

func (DropboxDiskType) Name() string {
	return "dropbox"
}

func (DropboxDiskType) Description() string {
	return "Dropbox cloud storage"
}

func (DropboxDiskType) ConfigTemplate() types.DiskTypeConfigTemplate {
	return types.DiskTypeConfigTemplate{
		"access_token": types.DiskTypeConfigField{
			Type:        "string",
			Description: "Dropbox API OAuth2 access token",
			Required:    true,
		},
	}
}

func (b *DropboxBackend) connect() error {
	token := b.mount.AccessToken
	if token == "" {
		return fmt.Errorf("missing required dropbox config field: access_token")
	}
	config := dropbox.Config{
		Token:    token,
		LogLevel: dropbox.LogInfo, // Or dropbox.LogOff
	}
	b.client = files.New(config)
	return nil
}

func (b *DropboxBackend) List(path string) ([]types.FileInfo, error) {
	if path == "" {
		path = "" // Dropbox root is ""
	}
	arg := files.NewListFolderArg(path)
	res, err := b.client.ListFolder(arg)
	if err != nil {
		errStr := err.Error()
		if strings.Contains(errStr, "missing_scope") {
			return nil, fmt.Errorf("Dropbox API error: missing required permission scope. Please check your app's permissions and access token. (error: %s)", errStr)
		}
		return nil, err
	}
	var out []types.FileInfo
	for _, entry := range res.Entries {
		switch f := entry.(type) {
		case *files.FileMetadata:
			out = append(out, types.FileInfo{
				Name:  f.Name,
				IsDir: false,
				Size:  int64(f.Size),
			})
		case *files.FolderMetadata:
			out = append(out, types.FileInfo{
				Name:  f.Name,
				IsDir: true,
				Size:  0,
			})
		}
	}
	return out, nil
}

func (b *DropboxBackend) Read(path string) ([]byte, error) {
	arg := files.NewDownloadArg(path)
	_, content, err := b.client.Download(arg)
	if err != nil {
		errStr := err.Error()
		if strings.Contains(errStr, "missing_scope") {
			return nil, fmt.Errorf("Dropbox API error: missing required permission scope. Please check your app's permissions and access token. (error: %s)", errStr)
		}
		return nil, err
	}
	defer content.Close()
	return io.ReadAll(content)
}

func (b *DropboxBackend) Write(path string, data []byte) error {
	arg := files.NewUploadArg(path)
	arg.Mode.Tag = "overwrite"
	_, err := b.client.Upload(arg, strings.NewReader(string(data)))
	if err != nil {
		errStr := err.Error()
		if strings.Contains(errStr, "missing_scope") {
			return fmt.Errorf("Dropbox API error: missing required permission scope. Please check your app's permissions and access token. (error: %s)", errStr)
		}
		return err
	}
	return nil
}

func (b *DropboxBackend) Delete(path string) error {
	arg := files.NewDeleteArg(path)
	_, err := b.client.DeleteV2(arg)
	if err != nil {
		errStr := err.Error()
		if strings.Contains(errStr, "missing_scope") {
			return fmt.Errorf("Dropbox API error: missing required permission scope. Please check your app's permissions and access token. (error: %s)", errStr)
		}
		return err
	}
	return nil
}

func (b *DropboxBackend) Reconnect() error {
	return b.connect()
}
