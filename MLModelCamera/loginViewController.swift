//
//  loginViewController.swift
//  MLModelCamera
//
//  Created by dima faris al saoudi on 23/06/2025.
//  Copyright © 2025 Shuichi Tsutsumi. All rights reserved.
//
import UIKit

class loginViewController: UIViewController {
    // If you want to connect any IBOutlet buttons or text fields, add them here
    @IBOutlet weak var emailTI: UITextField!
    
    @IBOutlet weak var passwordTI: UITextField!
    @IBOutlet weak var loginButton: UIButton!
    // @IBOutlet weak var usernameTextField: UITextField!
    // @IBOutlet weak var passwordTextField: UITextField!
    @IBAction func loginButtonTapped(_ sender: UIButton) {
        // Optionally: Add validation here
        performSegue(withIdentifier: "ViewController", sender: self)
    }

    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Any setup after loading the view
    }
    
}
