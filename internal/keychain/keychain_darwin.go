package keychain

// #cgo LDFLAGS: -framework Security
// #include <Security/Security.h>
// #include <stdlib.h>
// #include <string.h>
//
// static OSStatus setGenericPassword(const char *service, const char *account, const char *password) {
//     UInt32 serviceLen = strlen(service);
//     UInt32 accountLen = strlen(account);
//     UInt32 passwordLen = strlen(password);
//     OSStatus status = SecKeychainAddGenericPassword(NULL, serviceLen, service, accountLen, account, passwordLen, password, NULL);
//     if (status == errSecDuplicateItem) {
//         SecKeychainItemRef itemRef = NULL;
//         status = SecKeychainFindGenericPassword(NULL, serviceLen, service, accountLen, account, NULL, NULL, &itemRef);
//         if (status == errSecSuccess && itemRef) {
//             status = SecKeychainItemModifyAttributesAndData(itemRef, NULL, passwordLen, password);
//             CFRelease(itemRef);
//         }
//     }
//     return status;
// }
//
// static OSStatus getGenericPassword(const char *service, const char *account, char **outPassword, UInt32 *outLen, SecKeychainItemRef *outItemRef) {
//     return SecKeychainFindGenericPassword(NULL, strlen(service), service, strlen(account), account, outLen, (void **)outPassword, outItemRef);
// }
//
// static OSStatus deleteGenericPassword(const char *service, const char *account) {
//     SecKeychainItemRef itemRef = NULL;
//     OSStatus status = SecKeychainFindGenericPassword(NULL, strlen(service), service, strlen(account), account, NULL, NULL, &itemRef);
//     if (status == errSecSuccess && itemRef) {
//         status = SecKeychainItemDelete(itemRef);
//         CFRelease(itemRef);
//     }
//     return status;
// }
import "C"
import (
	"errors"
	"fmt"
	"unsafe"
)

var ErrNotFound = errors.New("keychain item not found")

func SetPassword(service, account, password string) error {
	cs := C.CString(service)
	ca := C.CString(account)
	cp := C.CString(password)
	defer C.free(unsafe.Pointer(cs))
	defer C.free(unsafe.Pointer(ca))
	defer C.free(unsafe.Pointer(cp))

	status := C.setGenericPassword(cs, ca, cp)
	if status != C.errSecSuccess {
		return fmt.Errorf("keychain set failed: %d", status)
	}
	return nil
}

func GetPassword(service, account string) (string, error) {
	cs := C.CString(service)
	ca := C.CString(account)
	defer C.free(unsafe.Pointer(cs))
	defer C.free(unsafe.Pointer(ca))

	var data *C.char
	var length C.UInt32
	var itemRef C.SecKeychainItemRef

	status := C.getGenericPassword(cs, ca, &data, &length, &itemRef)
	if status == C.errSecItemNotFound {
		return "", ErrNotFound
	}
	if status != C.errSecSuccess {
		return "", fmt.Errorf("keychain get failed: %d", status)
	}
	out := C.GoStringN(data, C.int(length))
	C.SecKeychainItemFreeContent(nil, unsafe.Pointer(data))
	if itemRef != C.SecKeychainItemRef(0) {
		C.CFRelease(C.CFTypeRef(itemRef))
	}
	return out, nil
}

func DeletePassword(service, account string) error {
	cs := C.CString(service)
	ca := C.CString(account)
	defer C.free(unsafe.Pointer(cs))
	defer C.free(unsafe.Pointer(ca))

	status := C.deleteGenericPassword(cs, ca)
	if status == C.errSecItemNotFound {
		return nil
	}
	if status != C.errSecSuccess {
		return fmt.Errorf("keychain delete failed: %d", status)
	}
	return nil
}
