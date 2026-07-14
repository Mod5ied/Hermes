//go:build !darwin

package keychain

import "errors"

var ErrNotFound = errors.New("keychain item not found")

func SetPassword(service, account, password string) error {
	return errors.New("keychain not supported on this platform")
}

func GetPassword(service, account string) (string, error) {
	return "", ErrNotFound
}

func DeletePassword(service, account string) error {
	return nil
}
