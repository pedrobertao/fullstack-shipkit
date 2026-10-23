package http

import (
	"errors"
	"reflect"
	"regexp"
	"strings"

	"github.com/go-playground/validator/v10"
	"github.com/gofiber/fiber/v2"
)

var (
	validate = newValidator()
	slugRe   = regexp.MustCompile(`^[a-z0-9]+(?:-[a-z0-9]+)*$`)
)

func newValidator() *validator.Validate {
	v := validator.New(validator.WithRequiredStructEnabled())

	v.RegisterTagNameFunc(func(f reflect.StructField) string {
		for _, tag := range []string{"json", "query", "params"} {
			name := strings.SplitN(f.Tag.Get(tag), ",", 2)[0]
			if name != "" && name != "-" {
				return name
			}
		}
		return f.Name
	})

	_ = v.RegisterValidation("slug", func(fl validator.FieldLevel) bool {
		return slugRe.MatchString(fl.Field().String())
	})

	return v
}

// bindAndValidate parses the JSON body and validates it. Use it in every handler with a body.
func bindAndValidate(c *fiber.Ctx, dst any) error {
	if err := c.BodyParser(dst); err != nil {
		return &APIError{Status: 400, Code: "invalid_json", Message: "invalid request body"}
	}
	return validateStruct(dst)
}

// bindQueryAndValidate does the same for query strings.
func bindQueryAndValidate(c *fiber.Ctx, dst any) error {
	if err := c.QueryParser(dst); err != nil {
		return &APIError{Status: 400, Code: "invalid_query", Message: "invalid query parameters"}
	}
	return validateStruct(dst)
}

func validateStruct(s any) error {
	err := validate.Struct(s)
	if err == nil {
		return nil
	}
	var verrs validator.ValidationErrors
	if !errors.As(err, &verrs) {
		return err // InvalidValidationError = a bug in our code, becomes a 500
	}
	fields := make(map[string]string, len(verrs))
	for _, fe := range verrs {
		fields[fieldPath(fe)] = messageFor(fe)
	}
	return &APIError{Status: 422, Code: "validation", Message: "invalid data", Fields: fields}
}

// "CreatePostInput.tags[2]" -> "tags[2]"
func fieldPath(fe validator.FieldError) string {
	ns := fe.Namespace()
	if i := strings.IndexByte(ns, '.'); i >= 0 {
		return ns[i+1:]
	}
	return fe.Field()
}

// messageFor turns a validator tag into a user-facing message. Add a case here
// whenever a new validate:"..." tag or custom validator is introduced.
func messageFor(fe validator.FieldError) string {
	p := fe.Param()
	isStr := fe.Kind() == reflect.String
	switch fe.Tag() {
	case "required":
		return "is required"
	case "email":
		return "must be a valid email"
	case "url":
		return "must be a valid URL"
	case "uuid4":
		return "must be a valid UUID"
	case "numeric":
		return "must be numeric"
	case "oneof":
		return "must be one of: " + strings.ReplaceAll(p, " ", ", ")
	case "min":
		if isStr {
			return "must be at least " + p + " characters"
		}
		return "must be at least " + p
	case "max":
		if isStr {
			return "must be at most " + p + " characters"
		}
		return "must be at most " + p
	case "len":
		return "must be exactly " + p + " characters"
	case "gt", "gte", "lt", "lte":
		ops := map[string]string{"gt": "greater than", "gte": "greater than or equal to", "lt": "less than", "lte": "less than or equal to"}
		return "must be " + ops[fe.Tag()] + " " + p
	case "eqfield":
		return "does not match " + strings.ToLower(p)
	case "slug":
		return "must contain only lowercase letters, numbers and hyphens"
	default:
		return "is invalid"
	}
}
