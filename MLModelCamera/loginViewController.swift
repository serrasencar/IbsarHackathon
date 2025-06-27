//
//  loginViewController.swift
//  MLModelCamera
//
//  Created by dima faris al saoudi on 23/06/2025.
//  Updated for UI polish and Arabic/English language menu support
//

import UIKit

class loginViewController: UIViewController {

    @IBOutlet weak var language: UIButton!
    @IBOutlet weak var emailTI: UITextField!
    @IBOutlet weak var passwordTI: UITextField!
    @IBOutlet weak var loginButton: UIButton!

    // Language flag
    var isArabicMode: Bool = false

    override func viewDidLoad() {
        super.viewDidLoad()

        setupLanguageMenu()
        
/*
        // Email field styling
       // emailTI.placeholder = "Enter your email"
        //emailTI.keyboardType = .emailAddress
        emailTI.autocapitalizationType = .none
        emailTI.autocorrectionType = .no
        emailTI.layer.cornerRadius = 8
        emailTI.layer.borderWidth = 1
        emailTI.layer.borderColor = UIColor.lightGray.cgColor
        emailTI.setLeftPaddingPoints(10)

        // Password field styling
        passwordTI.placeholder = "Enter your password"
        passwordTI.isSecureTextEntry = true
        passwordTI.autocorrectionType = .no
        passwordTI.layer.cornerRadius = 8
        passwordTI.layer.borderWidth = 1
        passwordTI.layer.borderColor = UIColor.lightGray.cgColor
        passwordTI.setLeftPaddingPoints(10)

 */
        // Login button styling
        loginButton.setTitle("Login", for: .normal)
        loginButton.layer.cornerRadius = 12
        loginButton.backgroundColor = UIColor.systemBlue
        loginButton.setTitleColor(.white, for: .normal)
        loginButton.layer.shadowColor = UIColor.black.cgColor
        loginButton.layer.shadowOpacity = 0.2
        loginButton.layer.shadowOffset = CGSize(width: 0, height: 3)
        loginButton.layer.shadowRadius = 4
    }

    private func setupLanguageMenu() {
        // Load previously saved language preference
        let isArabic = UserDefaults.standard.bool(forKey: "isArabicMode")

        // Create Arabic and English actions with selection states
        let arabic = UIAction(title: "Arabic", state: isArabic ? .on : .off) { _ in
            UserDefaults.standard.set(true, forKey: "isArabicMode")
            self.language.setTitle("Arabic", for: .normal)
            self.isArabicMode = true
            print("🌍 Arabic selected")
        }

        let english = UIAction(title: "English", state: isArabic ? .off : .on) { _ in
            UserDefaults.standard.set(false, forKey: "isArabicMode")
            self.language.setTitle("English", for: .normal)
            self.isArabicMode = false
            print("🌍 English selected")
        }

        // Set up the language menu with single selection mode
        let menu = UIMenu(title: "Select Language", options: .singleSelection, children: [arabic, english])
        language.menu = menu
        language.showsMenuAsPrimaryAction = true

        // Update button title on load
        self.language.setTitle(isArabic ? "Arabic" : "English", for: .normal)
        self.isArabicMode = isArabic
    }

    


    @IBAction func loginButtonTapped(_ sender: UIButton) {
        // Animate button
        UIView.animate(withDuration: 0.1,
                       animations: {
                           sender.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
                       },
                       completion: { _ in
                           UIView.animate(withDuration: 0.1) {
                               sender.transform = CGAffineTransform.identity
                           }
                       })

        // Basic validation
        guard let email = emailTI.text, !email.isEmpty,
              let password = passwordTI.text, !password.isEmpty else {
            shake(emailTI)
            shake(passwordTI)
            showAlert("Please enter both email and password.")
            return
        }

        // Perform segue
        performSegue(withIdentifier: "ViewController", sender: self)
    }


    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        print("🛠 prepare(for segue:) CALLED")
        if segue.identifier == "ViewController",
           let destination = segue.destination as? ViewController {
            destination.isArabicMode = self.isArabicMode
            print("✅ Arabic mode passed: \(self.isArabicMode)")
        } else {
            print("⚠️ Segue failed or wrong destination class")
        }
    }


    private func showAlert(_ message: String) {
        let alert = UIAlertController(title: "Login Required", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func shake(_ view: UIView) {
        let shake = CABasicAnimation(keyPath: "position")
        shake.duration = 0.05
        shake.repeatCount = 3
        shake.autoreverses = true
        shake.fromValue = NSValue(cgPoint: CGPoint(x: view.center.x - 5, y: view.center.y))
        shake.toValue = NSValue(cgPoint: CGPoint(x: view.center.x + 5, y: view.center.y))
        view.layer.add(shake, forKey: "position")
    }
}

// MARK: - Padding for text fields
extension UITextField {
    func setLeftPaddingPoints(_ amount: CGFloat) {
        let paddingView = UIView(frame: CGRect(x: 0, y: 0, width: amount, height: self.frame.height))
        self.leftView = paddingView
        self.leftViewMode = .always
    }
}

