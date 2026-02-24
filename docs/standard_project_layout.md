# Run Standard Project Layout

This is the standard layout for a Run project. Even though you can put your code wherever you want, this is the recommended layout.

```text
run_project/
├── cmd/
│   ├── main.run
│   └── other_command.run
├── pkg/
│   ├── user/
│   │   ├── user.run
│   │   └── user_test.run
│   └── order/
│       ├── order.run
│       └── order_test.run
├── lib/
│   ├── validation/
│   │   ├── validation.run
│   │   └── validation_test.run
│   └── dbconn/
│       ├── dbconn.run
│       └── dbconn_test.run
└── README.md
```

`pkg` represents the higher level modules of your project.
`lib` represents the lower level modules of your project.
`cmd` represents the command line tools of your project.
`README.md` is a placeholder for your project's README.

## Project Structure

### pkg

The `pkg` directory is used to store the higher level modules of your project.

### lib

The `lib` directory is used to store the lower level modules of your project.

### cmd

The `cmd` directory is used to store the command line tools of your project. Each command should be in its own file. The `cmd` 
